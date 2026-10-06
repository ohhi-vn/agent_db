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
  alias AgentDb.Store.{Commits, Memories, Nodes, Reader, Sessions, SQLite, Writer}

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

  # One statement for the whole family a write enqueues: the jobs are inserted
  # inside the caller's transaction either way, so this changes the number of
  # statements, not what a successful write guarantees.
  defp enqueue_jobs(conn, jobs), do: JobQueue.enqueue_many(conn, jobs)

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
         :ok <- enqueue_skill_work(conn, uri, content) do
      :ok
    end
  end

  # The same work a write enqueues, so an imported file is searchable and
  # summarized on the same terms as any other document.
  defp enqueue_skill_work(conn, uri, content) do
    JobQueue.enqueue_many(
      conn,
      Enum.map(JobQueue.all_kinds(), &{&1, %{uri: uri, content: content}})
    )
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

  # Embedding is computed successfully but there may be nowhere to put it: the
  # vec tables exist only with the sqlite-vec extension. The work is finished,
  # its result is simply not wanted, so the job completes rather than failing
  # and retrying an outcome that can never differ. Routing is per-request from
  # the blob itself (`dim = byte_size(blob)/4`); no cached pointer decides it.
  defp store_embedding(conn, job_id, uri, embedding) do
    if SQLite.vec_available?(conn) do
      case SQLite.vec_dim(embedding) do
        {:ok, dim} -> insert_embedding(conn, job_id, uri, embedding, dim)
        {:error, _} = err -> err
      end
    else
      discard(conn, job_id)
    end
  end

  defp insert_embedding(conn, job_id, uri, embedding, dim) do
    with :ok <- SQLite.ensure_vec_table(conn, dim) do
      table = SQLite.vec_table(dim)

      result =
        SQLite.exec_write(
          conn,
          """
          INSERT INTO "#{table}" (embedding, uri)
          VALUES (?1, ?2)
          ON CONFLICT(uri) DO UPDATE SET embedding = excluded.embedding
          """,
          [embedding, uri]
        )

      case result do
        :ok ->
          _ = SQLite.set_active_dim(conn, dim)

          finish(result, conn, job_id, fn ->
            Nodes.update_updated_at(conn, uri, System.system_time(:millisecond))
          end)

        {:error, _} = err ->
          err
      end
    end
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
  def search_keyword(term, scope_prefix, limit) do
    Reader.read(fn conn -> Nodes.search(conn, term, scope_prefix, limit) end)
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

  # The vec tables exist only when the sqlite-vec extension loaded, and a
  # query against them without the extension fails with the engine's own SQL
  # error text. That is not a reason a caller can act on, so the leg reports
  # itself as unservable instead. A query whose dim differs from the active
  # table is refused, never misranked across dims.
  defp vector_search(conn, query, top_k, scope_prefix) do
    if SQLite.vec_available?(conn) do
      with {:ok, query_dim} <- SQLite.vec_dim(query),
           {:ok, active} <- SQLite.get_active_dim(conn) do
        cond do
          active != :unknown and query_dim != active ->
            {:error, :dim_mismatch}

          not vec_table_exists?(conn, SQLite.vec_table(query_dim)) ->
            {:ok, []}

          true ->
            run_vector_search(conn, query, top_k, scope_prefix, SQLite.vec_table(query_dim))
        end
      else
        {:error, {:invalid_dim, _}} = err -> err
        {:error, _} = err -> err
      end
    else
      {:error, :vector_index_unavailable}
    end
  end

  defp vec_table_exists?(conn, table) do
    case SQLite.query_one(conn, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [
           table
         ]) do
      {:ok, [1]} -> true
      _ -> false
    end
  end

  defp run_vector_search(conn, query, top_k, scope_prefix, table) do
    base_query = """
      SELECT n.uri, n.parent_uri, n.name, n.kind, n.content, n.abstract, n.overview,
             vec_distance_cosine(v.embedding, ?1) as distance
      FROM "#{table}" v
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
    Writer.call(fn conn -> Sessions.create(conn) end)
  end

  @impl true
  def append_message(session_id, role, content) do
    Writer.call(fn conn -> Sessions.append(conn, session_id, role, content) end)
  end

  @impl true
  def get_session(session_id) do
    Reader.read(fn conn -> Sessions.read(conn, session_id) end)
  end

  @impl true
  def list_session_ids do
    Reader.read(fn conn -> Sessions.list_ids(conn) end)
  end

  @impl true
  def restore_session(session_id, messages) when is_binary(session_id) and is_list(messages) do
    Writer.call(fn conn ->
      SQLite.transaction(conn, fn conn -> Sessions.restore(conn, session_id, messages) end)
    end)
  end

  @impl true
  def commit_hash(session_id, destination_uri) do
    Reader.read(fn conn -> Commits.hash(conn, session_id, destination_uri) end)
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
             :ok <- Commits.record(conn, session_id, destination_uri, hash) do
          :ok
        end
      end)
    end
  end

  # -- memories --

  @impl true
  def put_memory(uri, value, confidence, source, opts \\ []) do
    with {:ok, segments} <- AgentDb.URI.parse(uri) do
      Writer.call(fn conn ->
        with :ok <- ensure_parents(conn, segments),
             :ok <-
               Nodes.upsert_doc(conn, uri, parent_uri(segments), List.last(segments), value, []),
             {:ok, _row} <- Memories.record(conn, uri, value, confidence, source, opts) do
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

  @impl true
  def promote_memory(uri) do
    Writer.call(fn conn ->
      case Memories.promote_candidate(conn, uri) do
        {:ok, _row} -> {:ok, :promoted}
        {:error, _} = err -> err
      end
    end)
  end

  # A rejected candidate leaves nothing behind. Recording it overwrote the
  # node document with the candidate value, so with no assertion left the
  # whole subtree state goes (the same purge a forget gets); with an active
  # belief remaining, the document is repaired to the active value.
  @impl true
  def reject_memory_candidate(uri) do
    with {:ok, segments} <- AgentDb.URI.parse(uri) do
      Writer.call(fn conn -> reject_candidate_state(conn, segments, uri) end)
    end
  end

  defp reject_candidate_state(conn, segments, uri) do
    with :ok <- Memories.reject_candidate(conn, uri),
         {:ok, active} <- Memories.active_at(conn, uri) do
      if active == nil do
        Nodes.purge_subtree(conn, uri)
      else
        Nodes.upsert_doc(conn, uri, parent_uri(segments), List.last(segments), active.value, [])
      end
    end
  end

  @impl true
  def mark_memories_surfaced(ids) do
    Writer.call(fn conn -> Memories.mark_surfaced(conn, ids, System.system_time(:millisecond)) end)
  end

  # Conflict detection reuses vectors already stored for memory URIs and runs
  # no inference of its own. Only same-type pairs are compared, which bounds
  # the quadratic scan by the taxonomy's own filing. A memory with no stored
  # vector is skipped; when none has one there is nothing to compare, which
  # is reported as unevaluable rather than as an empty verdict.
  @conflict_similarity 0.9

  @impl true
  def memory_conflict_pairs(prefix) do
    Reader.read(fn conn -> conflict_pairs(conn, prefix) end)
  end

  defp conflict_pairs(conn, prefix) do
    if SQLite.vec_available?(conn) do
      with {:ok, active_dim} <- SQLite.get_active_dim(conn),
           {:ok, rows} <- Memories.list(conn, prefix, nil, [:active]) do
        pairs_in_dim(conn, rows, active_dim)
      end
    else
      {:error, :embeddings_unavailable}
    end
  end

  defp pairs_in_dim(_conn, _rows, :unknown), do: {:error, :embeddings_unavailable}

  defp pairs_in_dim(conn, rows, dim) do
    table = SQLite.vec_table(dim)

    with {:ok, vectors} <- vectors_for(conn, table, rows) do
      if map_size(vectors) < 2 do
        {:error, :embeddings_unavailable}
      else
        {:ok, similar_pairs(rows, vectors)}
      end
    end
  end

  defp vectors_for(conn, table, rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case SQLite.query_one(conn, "SELECT embedding FROM \"#{table}\" WHERE uri = ?1", [row.uri]) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, [blob]} -> {:cont, {:ok, Map.put(acc, row.uri, blob)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp similar_pairs(rows, vectors) do
    uris = rows |> Enum.map(& &1.uri) |> Enum.filter(&Map.has_key?(vectors, &1)) |> Enum.uniq()

    for a <- uris,
        b <- uris,
        a < b,
        same_memory_type?(a, b),
        (sim = cosine(Map.fetch!(vectors, a), Map.fetch!(vectors, b))) >= @conflict_similarity do
      %{uri_a: a, uri_b: b, similarity: sim}
    end
    |> Enum.sort_by(& &1.similarity, :desc)
  end

  defp same_memory_type?(a, b), do: memory_type(a) == memory_type(b) and memory_type(a) != nil

  defp memory_type(uri) do
    case AgentDb.URI.parse(uri) do
      {:ok, ["user", "memories", type | _rest]} -> type
      _ -> nil
    end
  end

  defp cosine(a, b)
       when is_binary(a) and is_binary(b) and byte_size(a) > 0 and
              byte_size(a) == byte_size(b) and rem(byte_size(a), 4) == 0 do
    xs = for <<x::float-32 <- a>>, do: x
    ys = for <<y::float-32 <- b>>, do: y
    dot = Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    nx = :math.sqrt(Enum.map(xs, &(&1 * &1)) |> Enum.sum())
    ny = :math.sqrt(Enum.map(ys, &(&1 * &1)) |> Enum.sum())

    if nx == 0.0 or ny == 0.0, do: 0.0, else: dot / (nx * ny)
  end

  defp cosine(_, _), do: 0.0

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
  def fail_job(job_id, reason \\ nil), do: JobQueue.fail(job_id, reason)

  @impl true
  def defer_job(job_id, delay_ms), do: JobQueue.defer(job_id, delay_ms)

  @impl true
  def reset_running_jobs, do: JobQueue.reset_running_jobs()

  @impl true
  def queue_stats, do: JobQueue.stats()

  @impl true
  def queue_detail(limit), do: JobQueue.detail(limit)

  # -- composition and footprint --

  # Counts and file sizes for an operator looking at a store, not part of any
  # write path: read-only, grouped into a fixed number of queries, and honest
  # about the difference between "not reported" and zero.
  @impl true
  def stats do
    Reader.read(fn conn ->
      with {:ok, counts} <- Nodes.counts(conn),
           {:ok, by_subtree} <- Nodes.count_by_top_subtree(conn) do
        {:ok,
         Map.merge(counts, %{
           by_top_subtree: by_subtree,
           db_bytes: file_size(AgentDb.Config.db_path()),
           wal_bytes: file_size(AgentDb.Config.db_path() <> "-wal")
         })}
      end
    end)
  end

  # A WAL that has been checkpointed away has no file, which is not a size of
  # zero -- so a missing file reports nothing rather than an empty log.
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> nil
    end
  end

  @impl true
  def vector_index_stats do
    # `Nodes.counts/1` answers `{:ok, counts}` or nothing, so there is no error
    # to pass through here.
    Reader.read(fn conn ->
      {:ok, counts} = Nodes.counts(conn)
      vector_counts(conn, counts.documents)
    end)
  end

  # "The index is unavailable" and "the index holds nothing" are different
  # facts, and only the first of them means vector search cannot be served.
  # Reports the active dim, its vector count, the document count, and whether
  # URIs are missing from the active table.
  defp vector_counts(conn, documents) do
    if SQLite.vec_available?(conn) do
      with {:ok, active} <- SQLite.get_active_dim(conn) do
        case active do
          :unknown ->
            {:ok,
             %{
               available: true,
               active_dim: :unknown,
               vectors: 0,
               documents: documents,
               needs_backfill: documents > 0
             }}

          dim ->
            table = SQLite.vec_table(dim)

            case SQLite.query_one(conn, "SELECT COUNT(*) FROM \"#{table}\"", []) do
              {:ok, [vectors]} ->
                {:ok,
                 %{
                   available: true,
                   active_dim: dim,
                   vectors: vectors,
                   documents: documents,
                   needs_backfill: needs_backfill?(conn, table)
                 }}

              {:error, _} ->
                {:ok,
                 %{
                   available: true,
                   active_dim: dim,
                   vectors: 0,
                   documents: documents,
                   needs_backfill: documents > 0
                 }}
            end
        end
      end
    else
      {:ok,
       %{
         available: false,
         active_dim: :unknown,
         vectors: nil,
         documents: documents,
         needs_backfill: false
       }}
    end
  end

  defp needs_backfill?(conn, table) do
    case SQLite.query_one(
           conn,
           "SELECT EXISTS(SELECT 1 FROM nodes WHERE kind = 'doc' AND uri NOT IN (SELECT uri FROM \"#{table}\"))",
           []
         ) do
      {:ok, [1]} -> true
      _ -> false
    end
  end

  @doc """
  Enqueues `:embed` jobs only for URIs missing in the active dim table.

  Switching dims creates the new table if missing and backfills the diff;
  URIs already covered are never re-enqueued, and older dim tables are
  retained for cheap switch-back.
  """
  @spec backfill_vector_index() :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill_vector_index do
    Reader.read(fn conn ->
      with {:ok, active} <- SQLite.get_active_dim(conn),
           {:ok, docs} <- missing_uris(conn, active) do
        {:ok, {active, docs}}
      end
    end)
    |> case do
      {:ok, {:unknown, _}} -> {:ok, 0}
      {:ok, {active, docs}} -> enqueue_backfill(active, docs)
      {:error, _} = err -> err
    end
  end

  defp missing_uris(_conn, :unknown), do: {:ok, []}

  defp missing_uris(conn, dim) do
    table = SQLite.vec_table(dim)

    if vec_table_exists?(conn, table) do
      case SQLite.query(
             conn,
             "SELECT uri, content FROM nodes WHERE kind = 'doc' AND uri NOT IN (SELECT uri FROM \"#{table}\")",
             []
           ) do
        {:ok, rows} -> {:ok, Enum.map(rows, fn [uri, content] -> {uri, content} end)}
        {:error, _} = err -> err
      end
    else
      case SQLite.query(conn, "SELECT uri, content FROM nodes WHERE kind = 'doc'", []) do
        {:ok, rows} -> {:ok, Enum.map(rows, fn [uri, content] -> {uri, content} end)}
        {:error, _} = err -> err
      end
    end
  end

  defp enqueue_backfill(active, docs) do
    # Ensure the active table exists before jobs land, so the first write does
    # not race creation. Inert without the extension.
    _ =
      AgentDb.Store.Writer.call(fn conn ->
        if SQLite.vec_available?(conn) and active != :unknown do
          _ = SQLite.ensure_vec_table(conn, active)
        end

        :ok
      end)

    Enum.reduce_while(docs, {:ok, 0}, fn {uri, content}, {:ok, n} ->
      case enqueue_job(:embed, %{uri: uri, content: content || ""}) do
        {:ok, _} -> {:cont, {:ok, n + 1}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Drops a non-active dim table. Refuses the active dim; boot never wipes.
  """
  @spec prune_vector_index(pos_integer()) :: :ok | {:error, term()}
  def prune_vector_index(dim) do
    AgentDb.Store.Writer.call(fn conn -> SQLite.prune_vec_table(conn, dim) end)
  end

  @impl true
  def document_count(prefix) do
    Reader.read(fn conn -> Nodes.count_documents(conn, prefix) end)
  end

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
