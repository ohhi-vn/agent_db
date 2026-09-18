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
  alias AgentDb.Store.Nodes
  alias AgentDb.Store.Reader
  alias AgentDb.Store.Writer
  alias AgentDb.URI
  alias AgentDb.Config

  @type uri :: String.t()
  @type content :: String.t()

  # -- Tree operations --

  @doc """
  Writes a document at `uri` with full `content` (L2) plus optional
  caller-supplied `:abstract` (L0) and `:overview` (L1). Creates missing
  parent directories implicitly. Persists first, then invalidates caches.
  
  When `async_writes: true` (default), returns immediately and enqueues
  background jobs for embedding generation and LLM summarization.
  When `async_writes: false`, blocks until all background jobs complete.
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
    # Always enqueue embedding job
    JobQueue.enqueue(:embed, %{uri: uri, content: content})

    # Enqueue abstract summarization if not provided
    if Keyword.get(opts, :abstract) == nil do
      JobQueue.enqueue(:summarize_abstract, %{uri: uri, content: content})
    end

    # Enqueue overview summarization if not provided
    if Keyword.get(opts, :overview) == nil do
      JobQueue.enqueue(:summarize_overview, %{uri: uri, content: content})
    end
  end

  defp wait_for_background_jobs(uri, content, opts) do
    # For sync mode, we wait for all jobs to complete
    # This is a simplified implementation - in production you'd want
    # proper polling with timeout
    jobs_to_wait = 1  # embedding
    jobs_to_wait = jobs_to_wait + (if Keyword.get(opts, :abstract) == nil, do: 1, else: 0)
    jobs_to_wait = jobs_to_wait + (if Keyword.get(opts, :overview) == nil, do: 1, else: 0)

    enqueue_background_jobs(uri, content, opts)
    
    # Poll for completion with timeout
    timeout = 30_000  # 30 seconds
    poll_interval = 100
    max_polls = div(timeout, poll_interval)
    
    wait_for_jobs(uri, jobs_to_wait, max_polls, poll_interval)
  end

  defp wait_for_jobs(_uri, 0, _max_polls, _poll_interval), do: :ok
  
  defp wait_for_jobs(uri, _jobs_remaining, max_polls, poll_interval) when max_polls > 0 do
    :timer.sleep(poll_interval)
    
    # Check how many jobs are still pending/running for this URI
    remaining = count_pending_jobs(uri)
    
    if remaining == 0 do
      :ok
    else
      wait_for_jobs(uri, remaining, max_polls - 1, poll_interval)
    end
  end

  defp wait_for_jobs(_uri, _remaining, 0, _poll_interval) do
    # Timeout reached
    :ok
  end

  defp count_pending_jobs(uri) do
    Reader.read(fn conn ->
      case AgentDb.Store.SQLite.query_one(
             conn,
             """
             SELECT COUNT(*) FROM job_queue 
             WHERE (payload LIKE ?1 OR payload LIKE ?2 OR payload LIKE ?3)
             AND status IN ('pending', 'running')
             """,
             ["%#{uri}%", "%#{uri}%", "%#{uri}%"]
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
    scope = Keyword.get(opts, :scope)
    {w_keyword, w_vector} = Keyword.get(opts, :hybrid_weights, {0.5, 0.5})
    k = 60  # RRF constant

    _scope_prefix =
      case scope do
        nil -> nil
        uri ->
          case URI.parse(uri) do
            {:ok, segs} -> URI.scope_prefix(nil, segs)
            {:error, _} = err -> err
          end
      end

    # Run both searches in parallel
    keyword_task = Task.async(fn -> keyword_search(term, opts) end)
    vector_task = Task.async(fn -> vector_search(term, opts) end)

    {:ok, keyword_results} = Task.await(keyword_task, 10_000)
    {:ok, vector_results} = Task.await(vector_task, 10_000)

    # Reciprocal Rank Fusion
    fused = rrf_fuse(keyword_results, vector_results, k, w_keyword, w_vector)
    {:ok, Enum.take(fused, top_k)}
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
        {:ok, [[^hash]]} ->
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
