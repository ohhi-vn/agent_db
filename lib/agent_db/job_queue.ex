defmodule AgentDb.JobQueue do
  @moduledoc """
  The durable job queue: the SQL behind `AgentDb.Core.Storage`'s work
  operations.

  Every mutation runs on the single writer connection, so a claim is a
  serialized read-then-update rather than a race. Jobs survive a restart
  because they are rows, and a job left `running` by a process that died is
  returned to `pending` on the next boot.
  """

  alias AgentDb.Store.{Nodes, Reader, SQLite, Writer}

  # The connection every mutation runs on. `AgentDb.Store.SQLite` defines the
  # same type but is an internal module, so a type named here stays resolvable
  # in the generated reference instead of pointing at a hidden module.
  @type conn :: Exqlite.Sqlite3.db()

  @type kind :: :embed | :summarize_abstract | :summarize_overview
  @type payload :: map()
  @type status :: :pending | :running | :done | :failed

  @type job :: %{
          id: integer(),
          kind: kind(),
          payload: payload(),
          attempts: integer(),
          max_attempts: integer()
        }

  # How many claims one dequeue may lose before giving up. Reaching it means
  # another writer took every row this call selected, which is contention, not
  # an empty queue -- so a bounded retry rather than an unbounded one.
  @claim_attempts 3

  @doc """
  Enqueues a new job.

  `enqueue/3` is the same insertion on a connection the caller already holds, for
  a caller that has to record the job in the same transaction as the state the
  job is about. `enqueue/2` is that, on the writer.
  """
  @spec enqueue(kind(), payload()) :: {:ok, integer()} | {:error, term()}
  def enqueue(kind, payload), do: Writer.call(fn conn -> enqueue(conn, kind, payload) end)

  @doc """
  Enqueues a new job on a connection the caller holds.

  Takes the connection rather than acquiring the writer itself, because a
  replacement calls this from inside its own transaction on the writer
  connection, where a second claim on the writer would deadlock.
  """
  @spec enqueue(conn(), kind(), payload()) :: {:ok, integer()} | {:error, term()}
  def enqueue(conn, kind, payload) do
    now = System.system_time(:millisecond)

    with {:ok, json} <- encode_payload(payload),
         :ok <-
           SQLite.exec_write(
             conn,
             """
             INSERT INTO job_queue (kind, payload, status, scheduled_at, created_at, updated_at)
             VALUES (?1, ?2, 'pending', ?3, ?3, ?3)
             """,
             [to_string(kind), json, now]
           ) do
      {:ok, last_insert_rowid(conn)}
    end
  end

  defp encode_payload(payload) do
    case Jason.encode(payload) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  @doc """
  Enqueues several jobs with one INSERT on a connection the caller holds.

  A write always enqueues its whole family (embed plus summaries) in one
  transaction, so one statement replaces one per kind. Row ids are not
  returned; callers that need them keep using `enqueue/3`.
  """
  @spec enqueue_many(conn(), [{kind(), payload()}]) :: :ok | {:error, term()}
  def enqueue_many(_conn, []), do: :ok

  def enqueue_many(conn, jobs) do
    now = System.system_time(:millisecond)

    with {:ok, encoded} <- encode_many(jobs) do
      {placeholders, args} =
        encoded
        |> Enum.with_index()
        |> Enum.map(fn {{kind, json}, i} ->
          base = i * 3 + 1

          {"(?#{base}, ?#{base + 1}, 'pending', ?#{base + 2}, ?#{base + 2}, ?#{base + 2})",
           [to_string(kind), json, now]}
        end)
        |> Enum.unzip()

      SQLite.exec_write(
        conn,
        "INSERT INTO job_queue (kind, payload, status, scheduled_at, created_at, updated_at) VALUES " <>
          Enum.join(placeholders, ", "),
        List.flatten(args)
      )
    end
  end

  defp encode_many(jobs) do
    Enum.reduce_while(jobs, {:ok, []}, fn {kind, payload}, {:ok, acc} ->
      case Jason.encode(payload) do
        {:ok, json} -> {:cont, {:ok, [{kind, json} | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_payload, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Claims the next runnable job of one of `kinds` and advances its attempt count.

  A worker claims only the work it can run. Without the filter, a worker would
  claim a job belonging to another kind, be unable to interpret it, and fail
  it -- so idle work would be destroyed by the very pool meant to perform it.

  Selection and claim share one writer call, so no two workers can take the
  same row. The `changes()` check is a belt-and-braces guard: if the update
  matched nothing, another writer got there first and the claim is retried.
  """
  @spec dequeue([kind()]) :: {:ok, job()} | {:error, :empty} | {:error, term()}
  def dequeue(kinds \\ all_kinds()) do
    Writer.call(fn conn -> claim(conn, kinds, @claim_attempts) end)
  end

  @spec all_kinds() :: [kind()]
  def all_kinds, do: [:embed, :summarize_abstract, :summarize_overview]

  defp claim(conn, kinds, attempts_left) do
    marks = Enum.map_join(kinds, ", ", fn kind -> "'#{kind}'" end)
    now = System.system_time(:millisecond)

    case SQLite.query_one(
           conn,
           """
           SELECT id, kind, payload, attempts, max_attempts, scheduled_at
           FROM job_queue
           WHERE status = 'pending' AND scheduled_at <= ?1
             AND kind IN (#{marks})
           ORDER BY scheduled_at ASC
           LIMIT 1
           """,
           [now]
         ) do
      {:ok, nil} ->
        case reap_unknown_kind(conn) do
          :ok -> {:error, :empty}
          {:error, :empty} -> {:error, :empty}
          {:error, _} = err -> err
        end

      {:ok, [job_id, kind, payload_json, attempts, max_attempts, scheduled_at]} ->
        case claim_row(conn, job_id, attempts + 1) do
          :claimed ->
            case Jason.decode(payload_json) do
              {:ok, payload} ->
                {:ok,
                 %{
                   id: job_id,
                   kind: kind(kind),
                   payload: payload,
                   attempts: attempts + 1,
                   max_attempts: max_attempts,
                   queued_at: scheduled_at,
                   claimed_at: now
                 }}

              {:error, reason} ->
                _ = fail(conn, job_id, "invalid_payload")
                _ = reason
                {:error, :empty}
            end

          :lost when attempts_left > 1 ->
            claim(conn, kinds, attempts_left - 1)

          :lost ->
            {:error, :empty}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp reap_unknown_kind(conn) do
    case SQLite.query_one(
           conn,
           """
           SELECT id FROM job_queue
           WHERE status = 'pending'
             AND kind NOT IN ('embed', 'summarize_abstract', 'summarize_overview')
           ORDER BY scheduled_at ASC
           LIMIT 1
           """,
           []
         ) do
      {:ok, nil} -> {:error, :empty}
      {:ok, [job_id]} -> fail(conn, job_id, "unknown_job_kind")
      {:error, _} = err -> err
    end
  end

  # A kind read back from the database is turned into the atom this store
  # writes, never into a fresh one: a row nobody recognises travels on as text
  # so the worker can fail it as an invalid kind, and a corrupt row can neither
  # exhaust the atom table nor take the writer down.
  defp kind("embed"), do: :embed
  defp kind("summarize_abstract"), do: :summarize_abstract
  defp kind("summarize_overview"), do: :summarize_overview
  defp kind(other), do: other

  defp claim_row(conn, job_id, new_attempts) do
    now = System.system_time(:millisecond)

    with :ok <-
           SQLite.exec_write(
             conn,
             "UPDATE job_queue SET status = 'running', attempts = ?1, updated_at = ?2 WHERE id = ?3 AND status = 'pending'",
             [new_attempts, now, job_id]
           ),
         {:ok, [1]} <- SQLite.query_one(conn, "SELECT changes()", []) do
      :claimed
    else
      {:ok, [0]} -> :lost
      {:error, _} = err -> err
    end
  end

  @doc "Marks a job as completed successfully."
  @spec complete(integer()) :: :ok | {:error, term()}
  def complete(job_id), do: Writer.call(fn conn -> complete(conn, job_id) end)

  @spec complete(conn(), integer()) :: :ok | {:error, term()}
  def complete(conn, job_id) do
    SQLite.exec_write(
      conn,
      "UPDATE job_queue SET status = 'done', updated_at = ?1 WHERE id = ?2",
      [
        System.system_time(:millisecond),
        job_id
      ]
    )
  end

  @doc """
  Records a failure, scheduling a retry while attempts remain and marking the
  job failed once they are exhausted.

  `reason` is the classified failure the worker saw. It is stored so a failed
  job can be explained later without waiting for the log line that recorded it
  to still exist, and it is a classification -- never content, a prompt, or a
  credential.
  """
  @spec fail(integer(), String.t() | nil) :: :ok | {:error, term()}
  def fail(job_id, reason \\ nil), do: Writer.call(fn conn -> fail(conn, job_id, reason) end)

  @spec fail(conn(), integer(), String.t() | nil) :: :ok | {:error, term()}
  def fail(conn, job_id, reason) do
    now = System.system_time(:millisecond)

    case SQLite.query_one(conn, "SELECT attempts, max_attempts FROM job_queue WHERE id = ?1", [
           job_id
         ]) do
      {:ok, [attempts, max_attempts]} ->
        if attempts < max_attempts do
          # Exponential backoff: 1s, 2s, 4s, 8s, ... capped at 5 minutes.
          delay = min(300_000, round(:math.pow(2, attempts - 1) * 1000))

          SQLite.exec_write(
            conn,
            "UPDATE job_queue SET status = 'pending', scheduled_at = ?1, last_error = ?2, updated_at = ?3 WHERE id = ?4",
            [now + delay, reason, now, job_id]
          )
        else
          SQLite.exec_write(
            conn,
            "UPDATE job_queue SET status = 'failed', last_error = ?1, updated_at = ?2 WHERE id = ?3",
            [reason, now, job_id]
          )
        end

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Puts a job back without spending one of its attempts, for work that is
  waiting rather than failing.

  `dequeue/0` advances the attempt count when it claims a row, so a job merely
  waiting for a model would otherwise spend its budget on waiting.
  """
  @spec defer(integer(), non_neg_integer()) :: :ok | {:error, term()}
  def defer(job_id, delay_ms), do: Writer.call(fn conn -> requeue(conn, job_id, delay_ms) end)

  @spec requeue(conn(), integer(), non_neg_integer()) :: :ok | {:error, term()}
  def requeue(conn, job_id, delay_ms) do
    now = System.system_time(:millisecond)

    SQLite.exec_write(
      conn,
      """
      UPDATE job_queue
      SET status = 'pending',
          attempts = MAX(attempts - 1, 0),
          scheduled_at = ?1,
          updated_at = ?2
      WHERE id = ?3
      """,
      [now + delay_ms, now, job_id]
    )
  end

  @doc "Resets jobs left running by a previous run to pending."
  @spec reset_running_jobs() :: :ok | {:error, term()}
  def reset_running_jobs, do: Writer.call(fn conn -> reset_running_jobs(conn) end)

  @spec reset_running_jobs(conn()) :: :ok | {:error, term()}
  def reset_running_jobs(conn) do
    now = System.system_time(:millisecond)

    SQLite.exec_write(
      conn,
      "UPDATE job_queue SET status = 'pending', scheduled_at = ?1, updated_at = ?1 WHERE status = 'running'",
      [now]
    )
  end

  @doc """
  Deletes every job whose payload targets `uri` or a descendant, in any state.

  Takes a connection rather than acquiring the writer itself, because removal
  calls this from inside its own transaction on the writer connection.
  `cancel_jobs/1` is the same deletion for a caller that holds no connection.

  Matches the payload's `uri` field rather than the raw JSON text: a substring
  match would also delete jobs for unrelated URIs whose *content* happens to
  mention this one, silently dropping work outside the removed subtree.
  """
  @spec cancel_for_uri(conn(), String.t()) :: :ok | {:error, term()}
  def cancel_for_uri(conn, uri) do
    SQLite.exec_write(
      conn,
      """
      DELETE FROM job_queue
      WHERE json_extract(payload, '$.uri') = ?1
         OR json_extract(payload, '$.uri') LIKE ?2 ESCAPE '\\'
      """,
      [uri, Nodes.like_escape(uri <> "/") <> "%"]
    )
  end

  @spec cancel_jobs(String.t()) :: :ok | {:error, term()}
  def cancel_jobs(uri), do: Writer.call(fn conn -> cancel_for_uri(conn, uri) end)

  @doc "How many jobs target `uri` or a descendant and are in one of `statuses`."
  @spec count_for_uri(String.t(), [String.t()]) :: non_neg_integer()
  def count_for_uri(uri, statuses) do
    placeholders = Enum.map_join(statuses, ", ", fn _status -> "?" end)

    query =
      "SELECT COUNT(*) FROM job_queue " <>
        "WHERE json_extract(payload, '$.uri') = ?1 " <>
        "AND status IN (#{placeholders})"

    case Reader.read(fn conn -> SQLite.query_one(conn, query, [uri | statuses]) end) do
      {:ok, [count]} -> count
      _other -> 0
    end
  end

  @doc "Returns a map of job counts by status."
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    Reader.read(fn conn ->
      case SQLite.query(conn, "SELECT status, COUNT(*) as count FROM job_queue GROUP BY status") do
        {:ok, rows} ->
          {:ok, Enum.into(rows, %{}, fn [status, count] -> {status_of(status), count} end)}

        {:error, _} = err ->
          err
      end
    end)
  end

  @doc """
  How far behind the queue is and what is failing in it.

  `oldest_pending_ms` is the age of the longest-waiting pending job -- the one
  number that says whether the workers are keeping up -- and `nil` when nothing
  is pending. `failed` is the newest failures first, bounded by `limit`, each
  carrying the classified reason that was persisted when the job gave up.

  The URI comes out of the payload rather than a separate column, so it is read
  where it already is written.
  """
  @spec detail(pos_integer()) :: {:ok, map()} | {:error, term()}
  def detail(limit \\ 20) do
    Reader.read(fn conn ->
      with {:ok, [oldest]} <-
             SQLite.query_one(
               conn,
               "SELECT MIN(created_at) FROM job_queue WHERE status = 'pending'",
               []
             ),
           {:ok, rows} <- failed_rows(conn, limit) do
        {:ok, %{oldest_pending_ms: age_of(oldest), failed: rows}}
      else
        {:error, _} = err -> err
      end
    end)
  end

  defp failed_rows(conn, limit) do
    sql = """
    SELECT id, kind, json_extract(payload, '$.uri'), attempts, max_attempts, last_error, updated_at
    FROM job_queue
    WHERE status = 'failed'
    ORDER BY updated_at DESC
    LIMIT ?
    """

    case SQLite.query(conn, sql, [limit]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [id, kind, uri, attempts, max_attempts, reason, at] ->
           %{
             id: id,
             kind: kind,
             uri: uri,
             attempts: attempts,
             max_attempts: max_attempts,
             last_error: reason,
             failed_at: at
           }
         end)}

      {:error, _} = err ->
        err
    end
  end

  # NULL when nothing is pending: "no work" and "work waiting since the epoch"
  # must not read the same.
  defp age_of(nil), do: nil

  defp age_of(oldest) do
    max(0, System.system_time(:millisecond) - oldest)
  end

  defp status_of("pending"), do: :pending
  defp status_of("running"), do: :running
  defp status_of("done"), do: :done
  defp status_of("failed"), do: :failed
  defp status_of(other), do: other

  defp last_insert_rowid(conn) do
    case SQLite.query_one(conn, "SELECT last_insert_rowid()", []) do
      {:ok, [id]} -> id
      _other -> 0
    end
  end
end
