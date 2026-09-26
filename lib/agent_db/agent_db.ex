defmodule AgentDb do
  @moduledoc """
  Embedded offline context store for AI agents (OpenViking-inspired).

  SQLite is the source of truth; ETS caches are disposable read-through
  layers invalidated on every write. Supports vector search, LLM summarization,
  and optional WebSocket API for remote access.
  """

  alias AgentDb.Cache.Invalidate
  alias AgentDb.JobQueue
  alias AgentDb.ML.ModelManager
  alias AgentDb.Store.Memories
  alias AgentDb.Store.Nodes
  alias AgentDb.Store.Reader
  alias AgentDb.Store.Writer
  alias AgentDb.URI
  alias AgentDb.Config

  @sync_write_timeout_ms 30_000
  @sync_write_poll_ms 100

  # Memories live in a reserved subtree, and a memory's type is the first path
  # segment beneath it. Deriving the type from the URI rather than taking it as
  # an option is what keeps a memory an ordinary document: recall by type is
  # then a prefix query, and a memory's stated type can never contradict where
  # it is filed.
  @memories_root ["user", "memories"]
  @memory_types ~w(profile preferences entities events experiences)
  @default_confidence 0.5

  @type uri :: String.t()
  @type content :: String.t()

  # -- Tree operations --

  @doc """
  Writes a document at `uri` with full `content` (L2) plus optional
  caller-supplied `:abstract` (L0) and `:overview` (L1). Creates missing
  parent directories implicitly. Persists first, then invalidates caches.
  
  When `async_writes: true` (default), returns immediately and enqueues
  background jobs for embedding generation and LLM summarization.
  When `async_writes: false`, blocks until all background jobs complete and
  reports which of three things happened: completed (`:ok`), failed
  (`{:error, {:background_jobs_failed, uri}}`), or still outstanding
  (`{:error, {:background_jobs_pending, uri}}`). A failed job is never
  reported as success.

  Options:
    - `:async` - override `async_writes`
    - `:sync_timeout_ms` - how long sync mode waits before reporting work as
      still outstanding (default 30_000)
  """
  @spec write(uri(), content(), keyword()) :: :ok | {:error, term()}
  def write(uri, content, opts \\ []) when is_binary(content) do
    async = Keyword.get(opts, :async, Config.async_writes())
    
    with {:ok, segments} <- URI.parse(uri),
         {:ok, uri} <- persist_doc(segments, content, opts) do
      Invalidate.on_write(uri)
      
      if async do
        # Enqueue background jobs
        enqueue_background_jobs(uri, content, opts)
        :ok
      else
        # Sync mode: wait for jobs to complete
        wait_for_background_jobs(uri, content, opts)
      end
    else
      :root -> {:error, :is_root}
      {:error, _} = err -> err
    end
  end

  defp enqueue_background_jobs(uri, content, opts) do
    kinds =
      [:embed] ++
        summarization_kinds(opts)

    enqueue_jobs(uri, content, kinds)
  end

  # Summarization is skipped when the caller supplied that layer, so a re-write
  # that already carries an abstract does not pay to regenerate one.
  defp summarization_kinds(opts) do
    Enum.filter(
      [
        summarize_abstract: Keyword.get(opts, :abstract),
        summarize_overview: Keyword.get(opts, :overview)
      ],
      fn {_kind, supplied} -> supplied == nil end
    )
    |> Enum.map(&elem(&1, 0))
  end

  defp enqueue_jobs(uri, content, kinds) do
    Enum.each(kinds, &JobQueue.enqueue(&1, %{uri: uri, content: content}))
  end

  defp wait_for_background_jobs(uri, content, opts) do
    enqueue_background_jobs(uri, content, opts)
    timeout = Keyword.get(opts, :sync_timeout_ms, @sync_write_timeout_ms)
    await_jobs(uri, timeout, @sync_write_poll_ms)
  end

  # Sync mode reports which of three things happened. It used to return :ok
  # whenever the queue looked idle, but the pending count excluded 'failed', so
  # a job that died on its first attempt read as "nothing outstanding" and the
  # write reported success having done nothing.
  defp await_jobs(uri, timeout, poll_interval) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_jobs(uri, deadline, poll_interval)
  end

  defp do_await_jobs(uri, deadline, poll_interval) do
    cond do
      count_active_jobs(uri) > 0 ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:background_jobs_pending, uri}}
        else
          :timer.sleep(poll_interval)
          do_await_jobs(uri, deadline, poll_interval)
        end

      count_failed_jobs(uri) > 0 ->
        {:error, {:background_jobs_failed, uri}}

      true ->
        :ok
    end
  end

  defp count_active_jobs(uri), do: count_jobs(uri, ["pending", "running"])

  defp count_failed_jobs(uri), do: count_jobs(uri, ["failed"])

  defp count_jobs(uri, statuses) do
    placeholders = Enum.map_join(statuses, ", ", fn _ -> "?" end)

    Reader.read(fn conn ->
      query =
        "SELECT COUNT(*) FROM job_queue " <>
          "WHERE json_extract(payload, '$.uri') = ?1 " <>
          "AND status IN (#{placeholders})"

      case AgentDb.Store.SQLite.query_one(
             conn,
             query,
             [uri | Enum.map(statuses, & &1)]
           ) do
        {:ok, [count]} -> count
        _ -> 0
      end
    end)
  end

  @doc "Reads full document content (L2). ETS-first, SQLite fallback."
  @spec read(uri()) :: {:ok, content()} | {:error, term()}
  def read(uri) do
    with {:ok, segments} <- URI.parse(uri) do
      read_doc(segments, :content)
    else
      {:error, _} = err -> err
    end
  end

  @doc "Reads the L0 abstract, falling back to the first non-empty content line."
  @spec abstract(uri()) :: {:ok, content()} | {:error, term()}
  def abstract(uri) do
    with {:ok, segments} <- URI.parse(uri) do
      read_doc(segments, :abstract_resolved)
    else
      {:error, _} = err -> err
    end
  end

  @doc "Reads the L1 overview, falling back to the first 280 characters of content."
  @spec overview(uri()) :: {:ok, content()} | {:error, term()}
  def overview(uri) do
    with {:ok, segments} <- URI.parse(uri) do
      read_doc(segments, :overview_resolved)
    else
      {:error, _} = err -> err
    end
  end

  @doc "Lists direct children of a URI."
  @spec list(uri()) :: {:ok, [String.t()]} | {:error, term()}
  def list(uri) do
    case URI.parse(uri) do
      {:ok, []} -> list_children([])
      {:ok, segments} -> list_children(segments)
      {:error, _} = err -> err
    end
  end

  @doc "Depth-limited tree of a subtree (default depth 2)."
  @spec tree(uri(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def tree(uri, depth \\ 2)

  def tree(uri, depth) when is_integer(depth) and depth >= 1 do
    with {:ok, segments} <- URI.parse(uri),
         {:ok, node} <- fetch_node(segments) do
      build_tree(node, depth)
    else
      {:error, _} = err -> err
    end
  end

  @doc "Removes the subtree at `uri` recursively."
  @spec rm(uri()) :: :ok | {:error, term()}
  def rm(uri) do
    with {:ok, segments} <- URI.parse(uri),
         :ok <- persist_rm(segments) do
      Invalidate.on_rm(uri)
      :ok
    else
      :root -> {:error, :is_root}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # -- Search --

  @doc """
  Searches documents using keyword, vector, or hybrid search.
  
  Options:
    - :mode - :keyword (default), :vector, or :hybrid
    - :scope - URI prefix to limit search to subtree
    - :top_k - Maximum number of results (default 10)
    - :hybrid_weights - {keyword_weight, vector_weight} for hybrid mode (default {0.5, 0.5})
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(term, opts \\ []) do
    mode = Keyword.get(opts, :mode, :keyword)
    
    case mode do
      :keyword -> keyword_search(term, opts)
      :vector -> vector_search(term, opts)
      :hybrid -> hybrid_search(term, opts)
      _ -> {:error, {:invalid_mode, mode}}
    end
  end

  defp keyword_search(term, opts) do
    scope = Keyword.get(opts, :scope)

    scope_segments =
      case scope do
        nil -> nil
        uri ->
          case URI.parse(uri) do
            {:ok, segs} -> segs
            {:error, _} = err -> err
          end
      end

    scope_prefix =
      case scope_segments do
        nil -> nil
        segs -> URI.scope_prefix(nil, segs)
      end

    Reader.read(fn conn ->
      case Nodes.search(conn, term, scope_prefix) do
        {:ok, nodes} ->
          {:ok, Enum.map(nodes, &search_entry/1)}

        {:error, _} = err ->
          err
      end
    end)
  end

  defp vector_search(term, opts) do
    top_k = Keyword.get(opts, :top_k, 10)
    scope = Keyword.get(opts, :scope)

    scope_prefix =
      case scope do
        nil -> nil
        uri ->
          case URI.parse(uri) do
            {:ok, segs} -> URI.scope_prefix(nil, segs)
            {:error, _} = err -> err
          end
      end

    # Generate embedding for query
    case ModelManager.embed([term]) do
      {:ok, [query_embedding]} ->
        Reader.read(fn conn ->
          vector_search_impl(conn, query_embedding, top_k, scope_prefix)
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hybrid_search(term, opts) do
    top_k = Keyword.get(opts, :top_k, 10)
    {w_keyword, w_vector} = Keyword.get(opts, :hybrid_weights, {0.5, 0.5})
    k = 60  # RRF constant

    # Run both searches in parallel
    keyword_task = Task.async(fn -> keyword_search(term, opts) end)
    vector_task = Task.async(fn -> vector_search(term, opts) end)

    # Both legs are drained before either is inspected, so a failure in one
    # does not leave the other task's result unread.
    keyword_result = Task.await(keyword_task, 10_000)
    vector_result = Task.await(vector_task, 10_000)

    # Either leg can be unservable -- no vector index, or no embedding model.
    # That is reported to the caller rather than raised, so a remote client
    # gets an error response instead of a dead process.
    with {:ok, keyword_results} <- keyword_result,
         {:ok, vector_results} <- vector_result do
      # Reciprocal Rank Fusion
      fused = rrf_fuse(keyword_results, vector_results, k, w_keyword, w_vector)
      {:ok, Enum.take(fused, top_k)}
    end
  end

  defp vector_search_impl(conn, query_embedding, top_k, scope_prefix) do
    query_vector = Nx.to_binary(query_embedding)
    
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
          {base_query, [query_vector]}
        
        prefix ->
          {"#{base_query} AND n.uri LIKE ?2 ESCAPE '\\'", [query_vector, Nodes.like_escape(prefix) <> "%"]}
      end
    
    query = "#{where} ORDER BY distance ASC LIMIT ?#{length(args) + 1}"
    final_args = args ++ [top_k]

    case AgentDb.Store.SQLite.query(conn, query, final_args) do
      {:ok, rows} ->
        results = Enum.map(rows, fn [uri, _parent_uri, _name, _kind, content, abstract, overview, distance] ->
          %{
            uri: uri,
            content: content,
            abstract: abstract,
            overview: overview,
            score: 1.0 - distance  # Convert distance to similarity score
          }
        end)
        {:ok, results}

      {:error, err} ->
        {:error, err}
    end
  end

  defp rrf_fuse(keyword_results, vector_results, k, w_keyword, w_vector) do
    # Build rank maps
    keyword_ranks = Enum.with_index(keyword_results) |> Enum.into(%{}, fn {result, i} -> {result.uri, i + 1} end)
    vector_ranks = Enum.with_index(vector_results) |> Enum.into(%{}, fn {result, i} -> {result.uri, i + 1} end)

    # Collect all unique URIs
    all_uris = MapSet.union(MapSet.new(Map.keys(keyword_ranks)), MapSet.new(Map.keys(vector_ranks)))

    # Calculate RRF scores
    Enum.map(all_uris, fn uri ->
      kw_rank = Map.get(keyword_ranks, uri)
      vec_rank = Map.get(vector_ranks, uri)

      kw_score = if kw_rank, do: w_keyword * (1.0 / (kw_rank + k)), else: 0
      vec_score = if vec_rank, do: w_vector * (1.0 / (vec_rank + k)), else: 0

      # Get the result data from either source
      result = Enum.find(keyword_results, fn r -> r.uri == uri end) || 
               Enum.find(vector_results, fn r -> r.uri == uri end)

      Map.put(result, :score, kw_score + vec_score)
    end)
    |> Enum.sort_by(&(-&1.score))
  end

  defp search_entry(%{uri: uri, content: content, abstract: abstract, overview: overview} = _node) do
    %{
      uri: uri,
      content: content,
      abstract: abstract,
      overview: overview
    }
  end

  # -- Sessions --

  @doc "Creates a new session, returns its ID."
  @spec create_session() :: {:ok, String.t()} | {:error, term()}
  def create_session do
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    result =
      Writer.call(fn conn ->
        AgentDb.Store.SQLite.exec_write(
          conn,
          "INSERT INTO sessions (id, created_at) VALUES (?1, ?2)",
          [session_id, System.system_time(:millisecond)]
        )
      end)

    case result do
      :ok -> {:ok, session_id}
      {:error, _} = err -> err
    end
  end

  @doc "Appends a message to a session (role: :user | :assistant | :system)."
  @spec append_message(String.t(), atom(), String.t()) :: :ok | {:error, term()}
  def append_message(session_id, role, content) do
    Writer.call(fn conn ->
      seq =
        case AgentDb.Store.SQLite.query_one(
               conn,
               "SELECT MAX(seq) FROM session_messages WHERE session_id = ?1",
               [session_id]
             ) do
          {:ok, [nil]} -> 0
          {:ok, [n]} -> n + 1
          {:ok, []} -> 0
          {:error, _} = err -> err
        end

      AgentDb.Store.SQLite.exec_write(
        conn,
        "INSERT INTO session_messages (session_id, seq, role, content) VALUES (?1, ?2, ?3, ?4)",
        [session_id, seq, to_string(role), content]
      )
    end)
  end

  @doc "Returns all messages of a session in order."
  @spec get_session(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_session(session_id) do
    Reader.read(fn conn ->
      case AgentDb.Store.SQLite.query(
             conn,
             "SELECT seq, role, content FROM session_messages WHERE session_id = ?1 ORDER BY seq",
             [session_id]
           ) do
        {:ok, rows} ->
          {:ok,
           Enum.map(rows, fn [seq, role, content] ->
             %{seq: seq, role: String.to_existing_atom(role), content: content}
           end)}

        {:error, _} = err ->
          err
      end
    end)
  end

  # -- Commit session to context --

  @doc """
  Commits a session to the context tree at `destination_uri` as a single document.
  Idempotent per (session, destination): re-commit without new messages is a no-op.
  Returns {:ok, destination_uri} on commit, {:ok, :unchanged} when no new messages.
  """
  @spec commit_session(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | :unchanged} | {:error, term()}
  def commit_session(session_id, destination_uri, opts \\ []) do
    with {:ok, segments} <- URI.parse(destination_uri),
         {:ok, messages} <- get_session(session_id),
         {:ok, result} <- persist_commit(segments, session_id, messages, opts) do
      # :unchanged left SQLite untouched, so the cache already matches disk and
      # dropping it would be a wasted rebuild. A real commit rewrote the
      # document, so the warm cache would otherwise keep serving the content
      # from before this commit.
      if result != :unchanged, do: Invalidate.on_write(result)

      {:ok, result}
    else
      :root -> {:error, :is_root}
      {:error, _} = err -> err
    end
  end

  defp persist_commit(segments, session_id, messages, opts) do
    Writer.call(fn conn ->
      # Compute content hash for idempotency (D6)
      content =
        messages
        |> Enum.sort_by(& &1.seq)
        |> Enum.map_join("\n", fn m -> "#{m.role}: #{m.content}" end)

      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      # Check last committed hash
      case AgentDb.Store.SQLite.query_one(
             conn,
             "SELECT content_hash FROM commit_meta WHERE session_id = ?1 AND destination_uri = ?2",
             [session_id, URI.build(segments)]
           ) do
        {:ok, [^hash]} ->
          {:ok, :unchanged}

        _ ->
          # Build document content (can be overridden by opts[:formatter])
          content = Keyword.get(opts, :formatter, &format_messages/1).(messages)

          # Upsert the destination document
          uri = URI.build(segments)
          name = List.last(segments)
          parent = parent_uri(segments)

          # Ensure all parent directories exist (like persist_doc does)
          parents_ok = ensure_parents(conn, segments)

          with :ok <- parents_ok,
               :ok <- Nodes.ensure_dir(conn, uri, parent, name),
               :ok <-
                 Nodes.upsert_doc(conn, uri, parent, name, content, abstract: nil, overview: nil) do
            # Record commit hash
            :ok =
              AgentDb.Store.SQLite.exec_write(
                conn,
                """
                INSERT INTO commit_meta (session_id, destination_uri, content_hash, committed_at)
                VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(session_id, destination_uri) DO UPDATE SET
                  content_hash = excluded.content_hash,
                  committed_at = excluded.committed_at
                """,
                [session_id, uri, hash, System.system_time(:millisecond)]
              )

            {:ok, uri}
          end
      end
    end)
  end

  defp format_messages(messages) do
    Enum.map(messages, fn m -> "#{m.role}: #{m.content}" end)
    |> Enum.join("\n\n")
  end

  # -- Memory --

  @doc """
  Records a durable fact as a memory at `uri`, which must sit beneath
  `viking://user/memories/<type>/`. The `<type>` segment is drawn from
  `profile`, `preferences`, `entities`, `events`, `experiences` and is the
  memory's type.

  The URI is the identity of the thing being asserted, so recording at a URI
  that already holds a memory revises it: the prior value is retained as
  superseded and linked to the assertion that replaced it. Recording at a URI
  that holds nothing creates it.

  Recording enqueues embedding generation and no summarization: L0 and L1 exist
  to compress a document large enough that reading it whole is wasteful, and
  they can say nothing about an atomic fact that its value does not already say.
  No language model is required, so this succeeds with none loaded.

  Options:
    - `:confidence` - how firmly the fact is held, 0.0..1.0 (default #{@default_confidence})
    - `:source` - provenance, e.g. the originating session id

  Returns `{:ok, uri}`, `{:error, {:invalid_memory_type, type}}` for a type
  outside the taxonomy, `{:error, {:not_a_memory_uri, uri}}` for a URI outside
  the memories root, or `{:error, :invalid_uri}`.
  """
  @spec remember(uri(), content(), keyword()) :: {:ok, uri()} | {:error, term()}
  def remember(uri, value, opts \\ []) when is_binary(value) do
    confidence = Keyword.get(opts, :confidence, @default_confidence)
    source = Keyword.get(opts, :source)

    with {:ok, segments} <- memory_location(uri),
         :ok <- validate_confidence(confidence),
         {:ok, ^uri} <- persist_memory(segments, value, confidence, source) do
      Invalidate.on_write(uri)
      enqueue_jobs(uri, value, [:embed])
      {:ok, uri}
    end
  end

  @doc """
  Reads memories back. Accepts a URI directly, or options:

    - `:uri` - recall one memory or a subtree
    - `:type` - recall a whole type, e.g. `:events`
    - `:term` - restrict to memories whose value contains this substring
    - `:include_superseded` - also return superseded assertions, for inspecting
      how a memory's value changed (default `false`)

  `:uri` and `:type` both scope the recall; when both are given `:uri` wins.
  Results are ordered by descending confidence. A recall matching nothing
  returns `{:ok, []}`.

  Each entry carries `:id`, `:uri`, `:value`, `:type`, `:confidence`, `:source`,
  `:status`, `:supersedes` and `:updated_at`. With `include_superseded: true`,
  a superseded entry's `:supersedes` is the `:id` of the assertion that replaced
  it, so the chain can be walked from either end.
  """
  @spec recall(uri() | keyword()) :: {:ok, [map()]} | {:error, term()}
  def recall(uri_or_opts \\ [])

  def recall(uri) when is_binary(uri), do: recall(uri: uri)

  def recall(opts) when is_list(opts) do
    term = Keyword.get(opts, :term)

    statuses =
      if Keyword.get(opts, :include_superseded, false) do
        [:active, :superseded]
      else
        [:active]
      end

    with {:ok, prefix} <- recall_scope(opts) do
      Reader.read(fn conn ->
        case Memories.list(conn, prefix, term, statuses) do
          {:ok, rows} -> {:ok, Enum.map(rows, &memory_entry/1)}
          {:error, _} = err -> err
        end
      end)
    end
  end

  @doc """
  Removes the memory at `uri` along with its provenance: its value, every
  assertion recorded there including superseded ones, and its document. Returns
  `:ok`, or `{:error, :no_memory}` when no memory is recorded at that URI.

  Supersession, not forgetting, is what preserves history. A URI holding only
  an ordinary document is left alone.
  """
  @spec forget(uri()) :: :ok | {:error, term()}
  def forget(uri) do
    with {:ok, segments} <- URI.parse(uri),
         {:ok, true} <- memory_recorded?(uri),
         :ok <- persist_rm(segments) do
      Invalidate.on_rm(uri)
      :ok
    else
      :root -> {:error, :is_root}
      {:ok, false} -> {:error, :no_memory}
      {:error, _} = err -> err
    end
  end

  @doc "The memory types, for callers that need to enumerate the taxonomy."
  @spec memory_types() :: [String.t()]
  def memory_types, do: @memory_types

  @doc "The default confidence recorded when a caller supplies none."
  @spec default_confidence() :: float()
  def default_confidence, do: @default_confidence

  # Parses `uri` and checks it names a slot inside the memories root whose first
  # segment is a known type. Returns the segments to persist and the type.
  defp memory_location(uri) do
    case URI.parse(uri) do
      {:ok, [_user, "memories", type | rest]} when rest != [] ->
        if type in @memory_types do
          {:ok, URI.parse(uri) |> elem(1)}
        else
          {:error, {:invalid_memory_type, type}}
        end

      {:ok, _segments} ->
        {:error, {:not_a_memory_uri, uri}}

      {:error, :invalid_uri} ->
        {:error, :invalid_uri}
    end
  end

  defp validate_confidence(confidence) when is_number(confidence) do
    if confidence >= 0.0 and confidence <= 1.0 do
      :ok
    else
      {:error, {:invalid_confidence, confidence}}
    end
  end

  defp validate_confidence(confidence), do: {:error, {:invalid_confidence, confidence}}

  # Node and assertion are written in one Writer call so a memory can never
  # exist as a document with no assertion behind it, which would make it
  # invisible to recall while still occupying the URI. Memories.record/5 opens
  # its own transaction, which is safe here: Writer.call is a serialized call,
  # not a transaction, so nothing nests.
  defp persist_memory(segments, value, confidence, source) do
    Writer.call(fn conn ->
      uri = URI.build(segments)
      name = List.last(segments)
      parent = parent_uri(segments)

      with :ok <- ensure_parents(conn, segments),
           :ok <- Nodes.upsert_doc(conn, uri, parent, name, value, []),
           {:ok, _row} <- Memories.record(conn, uri, value, confidence, source) do
        {:ok, uri}
      else
        {:error, _} = err -> err
      end
    end)
  end

  defp memory_recorded?(uri) do
    Reader.read(fn conn -> Memories.exists_at?(conn, uri) end)
  end

  # `:uri` scopes directly; `:type` scopes to that type's subtree; neither
  # scopes to the whole memories root. The store matches a scope as
  # exact-uri-or-descendant, so no trailing separator is involved here and a
  # scope of `.../preferences` cannot reach a sibling `preferences-extra`.
  defp recall_scope(opts) do
    case {Keyword.get(opts, :uri), Keyword.get(opts, :type)} do
      {nil, nil} ->
        {:ok, memories_root_uri()}

      {uri, _type} when is_binary(uri) ->
        with :ok <- validate_memory_scope(uri) do
          {:ok, uri}
        end

      {nil, type} ->
        with {:ok, type} <- validate_memory_type(type) do
          {:ok, memories_root_uri() <> "/" <> type}
        end

      {_uri, type} ->
        # An explicit URI already fixes the scope; the type still has to be one
        # this store recognises, so a typo is reported rather than ignored.
        validate_memory_type(type)
    end
  end

  # A type arrives either as a URI segment (a string) or as an option a caller
  # naturally writes as an atom. Both resolve to the segment form, which is what
  # the URI and the taxonomy actually speak.
  defp validate_memory_type(type) when is_atom(type) and not is_nil(type) do
    validate_memory_type(Atom.to_string(type))
  end

  defp validate_memory_type(type) when is_binary(type) do
    if type in @memory_types, do: {:ok, type}, else: {:error, {:invalid_memory_type, type}}
  end

  defp validate_memory_type(type), do: {:error, {:invalid_memory_type, type}}

  defp validate_memory_scope(uri) do
    segments = URI.parse(uri) |> elem(1)

    if Enum.take(segments, length(@memories_root)) == @memories_root do
      :ok
    else
      {:error, {:not_a_memory_uri, uri}}
    end
  end

  defp memories_root_uri, do: URI.build(@memories_root)

  # `:id` is exposed so a superseded row's `:supersedes` can be resolved to the
  # assertion that replaced it; without it the chain is a dangling number.
  defp memory_entry(row) do
    row
    |> Map.take([:id, :uri, :value, :confidence, :source, :status, :supersedes, :updated_at])
    |> Map.put(:type, memory_type(row.uri))
  end

  defp memory_type(uri) do
    uri |> URI.parse() |> elem(1) |> Enum.at(length(@memories_root))
  end

  # -- internal tree helpers --

  defp persist_doc(segments, content, opts) do
    Writer.call(fn conn ->
      parents_ok = ensure_parents(conn, segments)

      with :ok <- parents_ok,
           uri = URI.build(segments),
           name = List.last(segments),
           parent = parent_uri(segments),
           :ok <- Nodes.upsert_doc(conn, uri, parent, name, content, opts) do
        {:ok, uri}
      else
        {:error, _} = err -> err
      end
    end)
  end

  defp ensure_parents(_conn, []), do: :ok

  defp ensure_parents(conn, segments) do
    segments
    |> Enum.drop(-1)
    |> Enum.scan([], fn seg, acc -> acc ++ [seg] end)
    |> Enum.reduce(:ok, fn
      _prefix, {:error, _} = err ->
        err

      prefix, :ok ->
        # The tree root ("viking://") is the parent of top-level nodes; make
        # sure it exists before inserting any node with parent_uri = "viking://".
        with :ok <- ensure_root(conn),
             dir_uri = URI.build(prefix),
             dir_name = List.last(prefix),
             :ok <- Nodes.ensure_dir(conn, dir_uri, parent_uri(prefix), dir_name) do
          :ok
        else
          {:error, _} = err -> err
        end
    end)
  end

  defp ensure_root(conn), do: Nodes.ensure_dir(conn, "viking://", nil, "")

  defp parent_uri([]), do: nil
  defp parent_uri(segments), do: URI.build(Enum.drop(segments, -1))

  defp read_doc(segments, field) do
    uri = URI.build(segments)

    cached =
      case AgentDb.Cache.Owner.get_node(uri) do
        {:ok, node} -> {:ok, node}
        :miss -> load_and_cache(uri)
      end

    case cached do
      {:ok, node} -> respond(node, field)
      {:error, _} = err -> err
    end
  end

  defp load_and_cache(uri) do
    Reader.read(fn conn ->
      case Nodes.get(conn, uri) do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, node} ->
          AgentDb.Cache.Owner.put_node(uri, node)
          {:ok, node}

        {:error, _} = err ->
          err
      end
    end)
  end

  defp respond(node, :content), do: {:ok, node.content || ""}
  defp respond(node, :abstract_resolved), do: {:ok, node.abstract || first_line(node.content)}
  defp respond(node, :overview_resolved), do: {:ok, node.overview || first_chars(node.content)}

  defp first_line(nil), do: ""

  defp first_line(content) do
    content
    |> String.split("\n")
    |> Enum.find("", &(&1 != ""))
    |> String.trim()
  end

  defp first_chars(nil), do: ""
  defp first_chars(content), do: String.slice(content, 0, 280)

  defp list_children([]) do
    # root listing: top-level children have parent_uri = "viking://"
    Reader.read(fn conn ->
      case Nodes.child_names(conn, "viking://") do
        {:ok, names} -> {:ok, MapSet.to_list(names) |> Enum.sort()}
        {:error, _} = err -> err
      end
    end)
  end

  defp list_children(segments) do
    uri = URI.build(segments)

    case AgentDb.Cache.Owner.get_dir(uri) do
      {:ok, names} ->
        {:ok, MapSet.to_list(names) |> Enum.sort()}

      :miss ->
        case dir_exists?(uri) do
          {:ok, true} ->
            names =
              Reader.read(fn conn ->
                Nodes.child_names(conn, uri)
              end)

            case names do
              {:ok, set} ->
                AgentDb.Cache.Owner.put_dir(uri, set)
                {:ok, MapSet.to_list(set) |> Enum.sort()}

              {:error, _} = err ->
                err
            end

          {:ok, false} ->
            {:error, :not_found}

          {:error, _} = err ->
            err
        end
    end
  end

  defp dir_exists?(uri) do
    Reader.read(fn conn ->
      case Nodes.get(conn, uri) do
        {:ok, %{kind: :dir}} -> {:ok, true}
        {:ok, _} -> {:ok, false}
        {:error, _} = err -> err
      end
    end)
  end

  defp fetch_node([]), do: {:error, :not_found}

  defp fetch_node(segments) do
    uri = URI.build(segments)

    case AgentDb.Cache.Owner.get_node(uri) do
      {:ok, node} -> {:ok, node}
      :miss -> load_and_cache(uri)
    end
  end

  defp build_tree(node, depth) do
    entry = tree_entry(node)

    # Depth 1 = the node itself plus its direct children names.
    case list_children(segments_of(node)) do
      {:ok, names} ->
        children =
          if depth <= 1 do
            names
          else
            build_children(node.uri, names, depth - 1)
          end

        {:ok, Map.put(entry, :children, children)}

      {:error, :not_found} ->
        {:ok, Map.put(entry, :children, [])}

      {:error, _} = err ->
        err
    end
  end

  defp build_children(parent_uri, names, remaining_depth) do
    Enum.map(names, fn name ->
      case URI.parse(parent_uri) do
        {:ok, segs} ->
          {:ok, child_segs} = URI.join(segs, name)
          child_uri = URI.build(child_segs)

          case load_and_cache(child_uri) do
            {:ok, child_node} ->
              case build_tree(child_node, remaining_depth) do
                {:ok, child_entry} -> child_entry
                _ -> tree_entry(child_node)
              end

            {:error, _} ->
              %{name: name, uri: child_uri, type: :missing}
          end

        _ ->
          %{name: name, uri: nil, type: :missing}
      end
    end)
  end

  defp segments_of(node), do: elem(URI.parse(node.uri), 1)

  defp tree_entry(%{kind: :dir} = node), do: %{name: node.name, uri: node.uri, type: :dir}

  defp tree_entry(%{kind: :doc} = node),
    do: %{name: node.name, uri: node.uri, type: :doc, abstract: node.abstract}

  defp persist_rm(segments) do
    uri = URI.build(segments)

    Writer.call(fn conn ->
      Nodes.rm_subtree(conn, uri)
    end)
  end
end
