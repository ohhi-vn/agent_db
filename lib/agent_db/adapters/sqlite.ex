defmodule AgentDb.Adapters.SQLite do
  @moduledoc false

  # The default storage provider: every durable record the store keeps, in one
  # SQLite file.
  #
  # One adapter rather than several, because the records are not independent.
  # A document, its vector, its queued inference, its commit bookkeeping and
  # its memory assertions all have to agree about which URIs exist, and the only
  # place that can be enforced is where they are written. `remove_subtree/1`
  # and the two `put_*_result` callbacks below are the operations that keep
  # that agreement, and each runs on a single writer connection so a concurrent
  # writer cannot interleave with it.
  #
  # Connections are not exposed to callers. `Store.Reader` hands out a pooled
  # read connection and `Store.Writer` the single write connection, and nothing
  # outside this module sees either.

  @behaviour AgentDb.Core.Storage

  alias AgentDb.JobQueue
  alias AgentDb.Store.{Memories, Nodes, Reader, SQLite, Writer}

  @impl true
  def child_specs(opts) do
    path = Keyword.fetch!(opts, :path)

    [
      {Writer, path: path},
      {Reader, path: path}
    ]
  end

  # -- documents and the tree --

  @impl true
  def get_node(uri) do
    Reader.read(fn conn -> Nodes.get(conn, uri) end)
  end

  @impl true
  def put_document(uri, content, opts) do
    with {:ok, segments} <- AgentDb.URI.parse(uri) do
      jobs = Keyword.get(opts, :jobs, [])

      Writer.call(fn conn ->
        SQLite.transaction(conn, fn conn ->
          write_document(conn, segments, content, opts, jobs)
        end)
      end)
    end
  end

  defp write_document(conn, segments, content, opts, jobs) do
    with :ok <- ensure_parents(conn, segments),
         uri = AgentDb.URI.build(segments),
         :ok <-
           Nodes.upsert_doc(conn, uri, parent_uri(segments), List.last(segments), content, opts),
         :ok <- enqueue_jobs(conn, jobs) do
      :ok
    end
  end

  defp enqueue_jobs(_conn, []), do: :ok

  defp enqueue_jobs(conn, jobs) do
    Enum.reduce_while(jobs, :ok, fn {kind, payload}, :ok ->
      case JobQueue.enqueue(conn, kind, payload) do
        {:ok, _id} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @impl true
  def list_children(uri) do
    Reader.read(fn conn ->
      with {:ok, node} <- Nodes.get(conn, uri) do
        case node do
          %{kind: :dir} -> children_names(conn, uri)
          _other -> {:error, :not_found}
        end
      end
    end)
  end

  defp children_names(conn, uri) do
    case Nodes.child_names(conn, uri) do
      {:ok, names} -> {:ok, names |> MapSet.to_list() |> Enum.sort()}
      {:error, _} = err -> err
    end
  end

  @impl true
  def remove_subtree(uri) do
    case AgentDb.URI.parse(uri) do
      {:ok, []} ->
        {:error, :is_root}

      {:ok, _segments} ->
        Writer.call(fn conn -> Nodes.rm_subtree(conn, uri) end)

      {:error, _} = err ->
        err
    end
  end

  # One transaction, on the single writer, for the whole skill: what was at the
  # URI, what is at it now, and the work enqueued for it. A step that fails takes
  # the previous subtree with it rather than leaving the URI holding half of one
  # skill's files and half of another's.
  @impl true
  def replace_skill(uri, files) do
    with {:ok, segments} <- AgentDb.URI.parse(uri) do
      Writer.call(fn conn ->
        SQLite.transaction(conn, fn conn -> replace(conn, segments, uri, files) end)
      end)
    end
  end

  defp replace(conn, segments, uri, files) do
    with {:ok, replaced} <- clear(conn, uri),
         :ok <- write_skill(conn, segments, files) do
      {:ok, %{replaced: replaced, files: length(files)}}
    end
  end

  # A skill the store already holds is replaced, and one it does not is written
  # into place: the report says which happened, and the two are told apart by
  # what was there before, not by a second lookup afterwards.
  defp clear(conn, uri) do
    case Nodes.exists?(conn, uri) do
      {:ok, true} -> purge(conn, uri, true)
      {:ok, false} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  defp purge(conn, uri, replaced) do
    case Nodes.purge_subtree(conn, uri) do
      :ok -> {:ok, replaced}
      {:error, _} = err -> err
    end
  end

  defp write_skill(conn, segments, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case write_skill_file(conn, segments, file) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp write_skill_file(conn, segments, %{path: path, content: content}) do
    segments = segments ++ path
    uri = AgentDb.URI.build(segments)

    with :ok <- ensure_parents(conn, segments),
         :ok <-
           Nodes.upsert_doc(conn, uri, parent_uri(segments), List.last(segments), content, []),
         {:ok, _job} <- enqueue_skill_work(conn, uri, content) do
      :ok
    end
  end

  # The same work a write enqueues, so an imported file is searchable and
  # summarized on the same terms as any other document.
  defp enqueue_skill_work(conn, uri, content) do
    Enum.reduce_while(JobQueue.all_kinds(), :ok, fn kind, :ok ->
      case JobQueue.enqueue(conn, kind, %{uri: uri, content: content}) do
        {:ok, _job} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # -- results of background inference --

  # The node may have been removed while the model was running. Embedding is
  # computed outside any transaction, so a removal that committed mid-compute
  # is invisible until we look now, and cancelling the queued job cannot close
  # that window because `dequeue_job/0` already claimed it. Re-checking on the
  # same connection that writes the result is what makes "a removed URI never
  # regains a summary or an embedding" hold, and the job is completed either
  # way: the work is finished, its result is simply not wanted.
  @impl true
  def put_embedding_result(job_id, uri, embedding) do
    Writer.call(fn conn ->
      case Nodes.exists?(conn, uri) do
        {:ok, true} -> store_embedding(conn, job_id, uri, embedding)
        {:ok, false} -> discard(conn, job_id)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def put_layer_result(job_id, uri, layer, text) do
    Writer.call(fn conn ->
      case Nodes.exists?(conn, uri) do
        {:ok, true} -> store_layer(conn, job_id, uri, layer, text)
        {:ok, false} -> discard(conn, job_id)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp discard(conn, job_id) do
    case JobQueue.complete(conn, job_id) do
      :ok -> {:ok, :discarded}
      {:error, _} = err -> err
    end
  end

  defp store_embedding(conn, job_id, uri, embedding) do
    result =
      SQLite.exec_write(
        conn,
        """
        INSERT INTO vec_nodes (embedding, uri)
        VALUES (?1, ?2)
        ON CONFLICT(uri) DO UPDATE SET embedding = excluded.embedding
        """,
        [embedding, uri]
      )

    finish(result, conn, job_id, fn ->
      Nodes.update_updated_at(conn, uri, System.system_time(:millisecond))
    end)
  end

  defp store_layer(conn, job_id, uri, layer, text) do
    column = if layer == :abstract, do: "abstract", else: "overview"

    result =
      SQLite.exec_write(
        conn,
        "UPDATE nodes SET #{column} = ?1, updated_at = ?2 WHERE uri = ?3",
        [text, System.system_time(:millisecond), uri]
      )

    finish(result, conn, job_id, fn -> :ok end)
  end

  # A store that succeeded and a job that was not marked done would leave work
  # to be redone, so the two are treated as one outcome.
  defp finish(:ok, conn, job_id, touch) do
    case touch.() do
      :ok ->
        case JobQueue.complete(conn, job_id) do
          :ok -> {:ok, :stored}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp finish({:error, _} = err, _conn, _job_id, _touch), do: err

  # -- search --

  @impl true
  def search_keyword(term, scope_prefix) do
    Reader.read(fn conn -> Nodes.search(conn, term, scope_prefix) end)
  end

  @impl true
  def find_paths(query, scope_uri, limit) do
    Reader.read(fn conn -> Nodes.find_paths(conn, query, scope_uri, limit) end)
  end

  @impl true
  def grep_content(query, scope_uri, limit) do
    Reader.read(fn conn -> Nodes.grep_content(conn, query, scope_uri, limit) end)
  end

  @impl true
  def search_vector(query, top_k, scope_prefix) do
    Reader.read(fn conn -> vector_search(conn, query, top_k, scope_prefix) end)
  end

  defp vector_search(conn, query, top_k, scope_prefix) do
    base_query = """
      SELECT n.uri, n.parent_uri, n.name, n.kind, n.content, n.abstract, n.overview,
             vec_distance_cosine(v.embedding, ?1) as distance
      FROM vec_nodes v
      JOIN nodes n ON n.uri = v.uri
      WHERE n.kind = 'doc'
    """

    {where, args} =
      case scope_prefix do
        nil ->
          {base_query, [query]}

        prefix ->
          {base_query <> " AND n.uri LIKE ?2 ESCAPE '\\'",
           [query, Nodes.like_escape(prefix) <> "%"]}
      end

    query = "#{where} ORDER BY distance ASC LIMIT ?#{length(args) + 1}"

    case SQLite.query(conn, query, args ++ [top_k]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [uri, _parent, _name, _kind, content, abstract, overview, distance] ->
           %{
             uri: uri,
             content: content,
             abstract: abstract,
             overview: overview,
             score: 1.0 - distance
           }
         end)}

      {:error, _} = err ->
        err
    end
  end

  # -- sessions --

  @impl true
  def create_session do
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    now = System.system_time(:millisecond)

    case Writer.call(fn conn ->
           SQLite.exec_write(conn, "INSERT INTO sessions (id, created_at) VALUES (?1, ?2)", [
             session_id,
             now
           ])
         end) do
      :ok -> {:ok, session_id}
      {:error, _} = err -> err
    end
  end

  @impl true
  def append_message(session_id, role, content) do
    Writer.call(fn conn ->
      with {:ok, seq} <- next_seq(conn, session_id) do
        SQLite.exec_write(
          conn,
          "INSERT INTO session_messages (session_id, seq, role, content) VALUES (?1, ?2, ?3, ?4)",
          [session_id, seq, to_string(role), content]
        )
      end
    end)
  end

  defp next_seq(conn, session_id) do
    case SQLite.query_one(conn, "SELECT MAX(seq) FROM session_messages WHERE session_id = ?1", [
           session_id
         ]) do
      {:ok, [nil]} -> {:ok, 0}
      {:ok, [n]} -> {:ok, n + 1}
      {:ok, []} -> {:ok, 0}
      {:error, _} = err -> err
    end
  end

  @impl true
  def get_session(session_id) do
    Reader.read(fn conn ->
      case SQLite.query(
             conn,
             "SELECT seq, role, content FROM session_messages WHERE session_id = ?1 ORDER BY seq",
             [session_id]
           ) do
        {:ok, rows} ->
          {:ok,
           Enum.map(rows, fn [seq, role, content] ->
             %{seq: seq, role: role(role), content: content}
           end)}

        {:error, _} = err ->
          err
      end
    end)
  end

  # A role is only ever one this store wrote, so an unknown value is a corrupt
  # row rather than a caller-supplied atom to be created on the spot.
  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("system"), do: :system
  defp role(other), do: other

  @impl true
  def list_session_ids do
    Reader.read(fn conn ->
      case SQLite.query(conn, "SELECT id FROM sessions ORDER BY id", []) do
        {:ok, rows} -> {:ok, Enum.map(rows, &hd/1)}
        {:error, _} = err -> err
      end
    end)
  end

  @impl true
  def restore_session(session_id, messages) when is_binary(session_id) and is_list(messages) do
    Writer.call(fn conn ->
      SQLite.transaction(conn, fn conn -> do_restore_session(conn, session_id, messages) end)
    end)
  end

  defp do_restore_session(conn, session_id, messages) do
    with {:ok, existing} <- read_session_messages(conn, session_id) do
      cond do
        same_messages?(existing, messages) -> {:ok, :skipped}
        existing != [] -> {:error, {:session_conflict, session_id}}
        true -> insert_restored_session(conn, session_id, messages)
      end
    end
  end

  defp read_session_messages(conn, session_id) do
    case SQLite.query(
           conn,
           "SELECT seq, role, content FROM session_messages WHERE session_id = ?1 ORDER BY seq",
           [session_id]
         ) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, fn [seq, role, content] -> %{seq: seq, role: role(role), content: content} end)}

      {:error, _} = err ->
        err
    end
  end

  defp same_messages?(existing, incoming) do
    Enum.map(existing, &{&1.role, &1.content}) ==
      Enum.map(incoming, &{normalize_role(&1.role), &1.content})
  end

  defp normalize_role(role) when is_atom(role), do: role
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("system"), do: :system
  defp normalize_role(other), do: other

  defp insert_restored_session(conn, session_id, messages) do
    now = System.system_time(:millisecond)

    with :ok <-
           SQLite.exec_write(conn, "INSERT OR IGNORE INTO sessions (id, created_at) VALUES (?1, ?2)", [
             session_id,
             now
           ]) do
      Enum.reduce_while(Enum.with_index(messages), :ok, fn {message, seq}, :ok ->
        case SQLite.exec_write(
               conn,
               "INSERT INTO session_messages (session_id, seq, role, content) VALUES (?1, ?2, ?3, ?4)",
               [session_id, seq, to_string(normalize_role(message.role)), message.content]
             ) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        :ok -> {:ok, :imported}
        {:error, _} = err -> err
      end
    end
  end

  @impl true
  def commit_hash(session_id, destination_uri) do
    Reader.read(fn conn ->
      case SQLite.query_one(
             conn,
             "SELECT content_hash FROM commit_meta WHERE session_id = ?1 AND destination_uri = ?2",
             [session_id, destination_uri]
           ) do
        {:ok, [hash]} -> {:ok, hash}
        {:ok, nil} -> {:ok, nil}
        {:error, _} = err -> err
      end
    end)
  end

  @impl true
  def put_commit(session_id, destination_uri, hash, content) do
    with {:ok, segments} <- AgentDb.URI.parse(destination_uri) do
      Writer.call(fn conn ->
        with :ok <- ensure_parents(conn, segments),
             :ok <-
               Nodes.ensure_dir(conn, destination_uri, parent_uri(segments), List.last(segments)),
             :ok <-
               Nodes.upsert_doc(
                 conn,
                 destination_uri,
                 parent_uri(segments),
                 List.last(segments),
                 content,
                 []
               ),
             :ok <-
               SQLite.exec_write(
                 conn,
                 """
                 INSERT INTO commit_meta (session_id, destination_uri, content_hash, committed_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(session_id, destination_uri) DO UPDATE SET
                   content_hash = excluded.content_hash,
                   committed_at = excluded.committed_at
                 """,
                 [session_id, destination_uri, hash, System.system_time(:millisecond)]
               ) do
          :ok
        end
      end)
    end
  end

  # -- memories --

  @impl true
  def put_memory(uri, value, confidence, source) do
    with {:ok, segments} <- AgentDb.URI.parse(uri) do
      Writer.call(fn conn ->
        with :ok <- ensure_parents(conn, segments),
             :ok <-
               Nodes.upsert_doc(conn, uri, parent_uri(segments), List.last(segments), value, []),
             {:ok, _row} <- Memories.record(conn, uri, value, confidence, source) do
          :ok
        else
          {:error, _} = err -> err
        end
      end)
    end
  end

  @impl true
  def recall_memories(prefix, term, statuses) do
    Reader.read(fn conn -> Memories.list(conn, prefix, term, statuses) end)
  end

  @impl true
  def memory_recorded?(uri) do
    Reader.read(fn conn -> Memories.exists_at?(conn, uri) end)
  end

  # -- durable work --

  @impl true
  def enqueue_job(kind, payload), do: JobQueue.enqueue(kind, payload)

  @impl true
  def cancel_jobs(uri), do: JobQueue.cancel_jobs(uri)

  @impl true
  def count_jobs(uri, statuses), do: JobQueue.count_for_uri(uri, statuses)

  @impl true
  def dequeue_job(kinds), do: JobQueue.dequeue(kinds)

  @impl true
  def complete_job(job_id), do: JobQueue.complete(job_id)

  @impl true
  def fail_job(job_id), do: JobQueue.fail(job_id)

  @impl true
  def defer_job(job_id, delay_ms), do: JobQueue.defer(job_id, delay_ms)

  @impl true
  def reset_running_jobs, do: JobQueue.reset_running_jobs()

  @impl true
  def queue_stats, do: JobQueue.stats()

  @impl true
  def healthy? do
    case Reader.read(fn conn -> SQLite.query_one(conn, "SELECT 1", []) end) do
      {:ok, [1]} -> true
      _other -> false
    end
  end

  # -- tree helpers --

  defp ensure_parents(_conn, []), do: :ok

  defp ensure_parents(conn, segments) do
    segments
    |> Enum.drop(-1)
    |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
    |> Enum.reduce(:ok, fn prefix, :ok ->
      # The tree root ("viking://") is the parent of top-level nodes, so it has
      # to exist before any node with that parent can be inserted.
      with :ok <- Nodes.ensure_dir(conn, "viking://", nil, "") do
        Nodes.ensure_dir(conn, AgentDb.URI.build(prefix), parent_uri(prefix), List.last(prefix))
      end
    end)
  end

  defp parent_uri([]), do: nil
  defp parent_uri(segments), do: AgentDb.URI.build(Enum.drop(segments, -1))
end
