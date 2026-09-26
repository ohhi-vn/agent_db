defmodule AgentDb.JobQueue do
  @moduledoc """
  SQLite-backed job queue for background processing of embeddings and summarization.
  
  Uses optimistic locking with single-writer serialization for concurrent dequeue.
  """

  alias AgentDb.Store.{Nodes, SQLite, Writer, Reader}

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

  @doc "Enqueues a new job."
  @spec enqueue(kind(), payload()) :: {:ok, integer()} | {:error, term()}
  def enqueue(kind, payload) do
    Writer.call(fn conn ->
      now = System.system_time(:millisecond)
      payload_json = Jason.encode!(payload)

      case SQLite.exec_write(
             conn,
             """
             INSERT INTO job_queue (kind, payload, status, scheduled_at, created_at, updated_at)
             VALUES (?1, ?2, 'pending', ?3, ?3, ?3)
             """,
             [to_string(kind), payload_json, now]
           ) do
        :ok ->
          {:ok, last_insert_rowid(conn)}

        {:error, _} = err ->
          err
      end
    end)
  end

  @doc "Dequeues the next pending job for a worker."
  @spec dequeue(String.t()) :: {:ok, job()} | {:error, :empty} | {:error, term()}
  def dequeue(worker_id) do
    Writer.call(fn conn ->
      now = System.system_time(:millisecond)

      # Use a two-step approach: select then update with status check
      # This works because Writer serializes all calls
      case SQLite.query_one(
             conn,
             """
             SELECT id, kind, payload, status, attempts, max_attempts, scheduled_at, created_at, updated_at
             FROM job_queue
             WHERE status = 'pending' AND scheduled_at <= ?1
             ORDER BY scheduled_at ASC
             LIMIT 1
             """,
             [now]
           ) do
        {:ok, nil} ->
          {:error, :empty}

        {:ok, row} ->
          [job_id, kind_str, payload_json, _status, attempts, max_attempts, _scheduled_at, _created_at, _updated_at] = row
          kind = String.to_atom(kind_str)
          payload = Jason.decode!(payload_json)

          # Atomically claim the job by updating status (optimistic locking)
          new_attempts = attempts + 1
          case SQLite.exec_write(
                 conn,
                 """
                 UPDATE job_queue
                 SET status = 'running', attempts = ?1, updated_at = ?2
                 WHERE id = ?3 AND status = 'pending'
                 """,
                 [new_attempts, now, job_id]
               ) do
            :ok ->
              # Check if row was actually updated
              case SQLite.query_one(
                     conn,
                     "SELECT changes()",
                     []
                   ) do
                {:ok, [1]} ->
                  {:ok, %{
                    id: job_id,
                    kind: kind,
                    payload: payload,
                    attempts: new_attempts,
                    max_attempts: max_attempts
                  }}

                {:ok, [0]} ->
                  # Another worker got it, retry
                  dequeue(worker_id)

                {:error, _} = err ->
                  err
              end

            {:error, _} = err ->
              err
          end

        {:error, _} = err ->
          err
      end
    end)
  end

  @doc """
  Marks a job as completed successfully.

  `complete/1` acquires the writer; `complete/2` runs on a connection the
  caller already holds. Workers must use `complete/2`, because they persist
  their result inside a `Writer.call/1` and calling `complete/1` from there
  would be a GenServer call to the writer from inside the writer.
  """
  @spec complete(integer()) :: :ok | {:error, term()}
  def complete(job_id) do
    Writer.call(fn conn -> complete(conn, job_id) end)
  end

  @spec complete(SQLite.conn(), integer()) :: :ok | {:error, term()}
  def complete(conn, job_id) do
    now = System.system_time(:millisecond)
    SQLite.exec_write(
      conn,
      """
      UPDATE job_queue
      SET status = 'done', updated_at = ?1
      WHERE id = ?2
      """,
      [now, job_id]
    )
  end

  @doc """
  Marks a job as failed, scheduling retry if attempts < max_attempts.

  As with `complete/2`, workers must use `fail/3` from inside a `Writer.call/1`.
  """
  @spec fail(integer(), term()) :: :ok | {:error, term()}
  def fail(job_id, reason) do
    Writer.call(fn conn -> fail(conn, job_id, reason) end)
  end

  @spec fail(SQLite.conn(), integer(), term()) :: :ok | {:error, term()}
  def fail(conn, job_id, _reason) do
    now = System.system_time(:millisecond)

    case SQLite.query_one(
           conn,
           "SELECT attempts, max_attempts FROM job_queue WHERE id = ?1",
           [job_id]
         ) do
      {:ok, [attempts, max_attempts]} ->
        if attempts < max_attempts do
          # Exponential backoff: 1s, 2s, 4s, 8s, 16s... max 5min
          delay = min(300_000, :math.pow(2, attempts - 1) * 1000 |> round())
          scheduled_at = now + delay

          SQLite.exec_write(
            conn,
            """
            UPDATE job_queue
            SET status = 'pending', scheduled_at = ?1, updated_at = ?2
            WHERE id = ?3
            """,
            [scheduled_at, now, job_id]
          )
        else
          SQLite.exec_write(
            conn,
            """
            UPDATE job_queue
            SET status = 'failed', updated_at = ?1
            WHERE id = ?2
            """,
            [now, job_id]
          )
        end

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  @doc "Resets running jobs to pending on startup (recovery)."
  @spec reset_running_jobs() :: :ok | {:error, term()}
  def reset_running_jobs do
    Writer.call(fn conn -> reset_running_jobs(conn) end)
  end

  @spec reset_running_jobs(SQLite.conn()) :: :ok | {:error, term()}
  def reset_running_jobs(conn) do
    now = System.system_time(:millisecond)
    SQLite.exec_write(
      conn,
      """
      UPDATE job_queue
      SET status = 'pending', attempts = 0, scheduled_at = ?1, updated_at = ?1
      WHERE status = 'running'
      """,
      [now]
    )
  end

  @doc """
  Deletes every job whose payload targets `uri` or a descendant of it, in any
  state (`pending`, `running`, `done`, or `failed`).

  Takes a connection rather than acquiring the writer itself, because removal
  calls this from inside its own transaction on the writer connection.

  Matches on the payload's `uri` field rather than the raw JSON text: a
  substring match would also delete jobs for unrelated URIs whose *content*
  happens to mention this one, which would silently drop work outside the
  removed subtree.
  """
  @spec cancel_for_uri(SQLite.conn(), String.t()) :: :ok | {:error, term()}
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

  @doc """
  Returns a job to `pending` without consuming a retry attempt.

  `dequeue/1` advances `attempts` when it claims a row, so a job that is merely
  waiting for a model would otherwise spend its budget on waiting. This gives
  the attempt back and reschedules, keeping the retry budget for failures that
  can actually succeed on retry.
  """
  @spec requeue(SQLite.conn(), integer(), non_neg_integer()) :: :ok | {:error, term()}
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

  @doc """
  Reschedules a job without consuming a retry attempt, for work that is merely
  waiting rather than failing.
  """
  @spec defer(integer(), non_neg_integer()) :: :ok | {:error, term()}
  def defer(job_id, delay_ms) do
    Writer.call(fn conn -> requeue(conn, job_id, delay_ms) end)
  end

  @doc "Gets queue statistics."
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    Reader.read(fn conn ->
      case SQLite.query(
             conn,
             """
             SELECT status, COUNT(*) as count
             FROM job_queue
             GROUP BY status
             """
           ) do
        {:ok, rows} ->
          stats = Enum.into(rows, %{}, fn [status, count] -> {String.to_atom(status), count} end)
          {:ok, stats}

        {:error, _} = err ->
          err
      end
    end)
  end

  # -- Helpers --

  defp last_insert_rowid(conn) do
    case SQLite.query_one(conn, "SELECT last_insert_rowid()", []) do
      {:ok, [id]} -> id
      _ -> 0
    end
  end
end