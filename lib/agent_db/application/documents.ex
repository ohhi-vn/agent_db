defmodule AgentDb.Application.Documents do
  @moduledoc false

  # Writing, reading and removing documents, and the tree they form.
  #
  # Every call reaches the store through the storage port, and answers in the
  # terms the port speaks: URIs in, nodes and results out. What this workflow
  # owns is what those answers mean -- which layer a read resolves to when the
  # stored one is missing, how a write acknowledges, when a write is complete
  # -- and none of how any of it is stored.

  alias AgentDb.Cache
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @type uri :: String.t()
  @type content :: String.t()

  @write_timeout_ms 30_000
  @poll_interval_ms 100

  # -- writing --

  @doc """
  Writes a document at `uri` with full content (L2), creating missing parents.

  Persists, invalidates, and only then acknowledges. The layers the caller
  supplied are kept as given; the ones it did not are enqueued for generation,
  and a re-write that already carries a layer does not pay to regenerate it.

  With `async: true` (the default) this returns as soon as the document is
  durable. With `async: false` it waits for that document's own work and
  reports which of three things happened: it completed, it failed, or it is
  still outstanding.

  Options:
    - `:async` - override `async_writes`
    - `:sync_timeout_ms` - how long a synchronous write waits before reporting
      work as still outstanding (default 30_000)
    - `:abstract` / `:overview` - the caller's own L0 / L1 layers
  """
  @spec write(uri(), content(), keyword()) :: :ok | {:error, term()}
  def write(uri, content, opts \\ []) when is_binary(content) do
    async = Keyword.get(opts, :async, AgentDb.Config.async_writes())

    with {:ok, segments} <- VikingURI.parse(uri),
         :ok <- persist(segments, content, opts) do
      Cache.invalidate_write(uri)

      if async do
        enqueue(uri, content, kinds_for(opts))
        :ok
      else
        settle(uri, content, opts)
      end
    else
      :root -> {:error, :is_root}
      {:error, _} = err -> err
    end
  end

  defp persist(segments, content, opts) do
    Runtime.storage().put_document(VikingURI.build(segments), content, opts)
  end

  # A layer the caller supplied is already stored, so regenerating it would
  # cost a model call to arrive at something already known.
  defp kinds_for(opts) do
    missing =
      [summarize_abstract: opts[:abstract], summarize_overview: opts[:overview]]
      |> Enum.filter(fn {_kind, supplied} -> supplied == nil end)
      |> Enum.map(&elem(&1, 0))

    [:embed | missing]
  end

  defp enqueue(uri, content, kinds) do
    storage = Runtime.storage()
    Enum.each(kinds, &storage.enqueue_job(&1, %{uri: uri, content: content}))
  end

  # A synchronous caller is told which of three things happened. The pending
  # count once excluded failed rows, so a job that died on its first attempt
  # read as an idle queue and the write reported success having done nothing.
  defp settle(uri, content, opts) do
    enqueue(uri, content, kinds_for(opts))

    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :sync_timeout_ms, @write_timeout_ms)

    await(uri, deadline)
  end

  defp await(uri, deadline) do
    storage = Runtime.storage()

    cond do
      storage.count_jobs(uri, ["pending", "running"]) > 0 -> await_or_outstanding(uri, deadline)
      storage.count_jobs(uri, ["failed"]) > 0 -> {:error, {:background_jobs_failed, uri}}
      true -> :ok
    end
  end

  defp await_or_outstanding(uri, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:background_jobs_pending, uri}}
    else
      :timer.sleep(@poll_interval_ms)
      await(uri, deadline)
    end
  end

  # -- reading --

  @doc "Reads full document content (L2)."
  @spec read(uri()) :: {:ok, content()} | {:error, term()}
  def read(uri) do
    with {:ok, segments} <- VikingURI.parse(uri) do
      layer(segments, & &1.content)
    end
  end

  @doc """
  Reads the L0 abstract, falling back to the first non-empty content line.

  The fallback is what makes a document readable at all when no model is
  available, so it is a value the store always has rather than an error the
  caller has to handle.
  """
  @spec abstract(uri()) :: {:ok, content()} | {:error, term()}
  def abstract(uri) do
    with {:ok, segments} <- VikingURI.parse(uri) do
      layer(segments, fn node -> node.abstract || first_line(node.content) end)
    end
  end

  @doc "Reads the L1 overview, falling back to the first 280 characters of content."
  @spec overview(uri()) :: {:ok, content()} | {:error, term()}
  def overview(uri) do
    with {:ok, segments} <- VikingURI.parse(uri) do
      layer(segments, fn node -> node.overview || first_chars(node.content) end)
    end
  end

  defp layer(segments, select) do
    with {:ok, node} <- fetch(segments) do
      {:ok, select.(node) || ""}
    end
  end

  defp first_line(nil), do: ""

  defp first_line(content),
    do: content |> String.split("\n") |> Enum.find("", &(&1 != "")) |> String.trim()

  defp first_chars(nil), do: ""
  defp first_chars(content), do: String.slice(content, 0, 280)

  @doc "Lists the names of a URI's direct children, and only those."
  @spec list(uri()) :: {:ok, [String.t()]} | {:error, term()}
  def list(uri) do
    case VikingURI.parse(uri) do
      {:ok, segments} -> Runtime.storage().list_children(VikingURI.build(segments))
      {:error, _} = err -> err
    end
  end

  @doc "A depth-limited projection of the tree at `uri` (default depth 2)."
  @spec tree(uri(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def tree(uri, depth \\ 2)

  def tree(uri, depth) when is_integer(depth) and depth >= 1 do
    with {:ok, segments} <- VikingURI.parse(uri),
         {:ok, node} <- fetch_entry(segments) do
      project(node, depth)
    end
  end

  defp fetch_entry([]), do: {:error, :not_found}
  defp fetch_entry(segments), do: fetch(segments)

  # Depth 1 is the node's own direct children, by name. Deeper is one level of
  # entries, each expanded by the depth that remains.
  defp project(node, depth) do
    case list(node.uri) do
      {:ok, names} -> {:ok, Map.put(entry(node), :children, children(node, names, depth))}
      {:error, :not_found} -> {:ok, Map.put(entry(node), :children, [])}
      {:error, _} = err -> err
    end
  end

  defp children(_node, names, 1), do: names

  defp children(%{uri: uri}, names, depth) do
    Enum.map(names, fn name ->
      case descend(uri, name) do
        {:ok, child_node} ->
          case project(child_node, depth - 1) do
            {:ok, projected} -> projected
            {:error, _} -> entry(child_node)
          end

        {:error, _} ->
          %{name: name, uri: child_uri(uri, name), type: :missing}
      end
    end)
  end

  defp descend(parent_uri, name) do
    with {:ok, segments} <- VikingURI.parse(parent_uri),
         {:ok, child_segments} <- VikingURI.join(segments, name) do
      fetch(child_segments)
    end
  end

  defp child_uri(parent_uri, name) do
    case descend(parent_uri, name) do
      {:ok, node} -> node.uri
      {:error, _} -> nil
    end
  end

  defp entry(%{kind: :dir} = node), do: %{name: node.name, uri: node.uri, type: :dir}

  defp entry(%{kind: :doc} = node),
    do: %{name: node.name, uri: node.uri, type: :doc, abstract: node.abstract}

  # -- removing --

  @doc "Removes the subtree at `uri`, from every store keyed by URI."
  @spec rm(uri()) :: :ok | {:error, term()}
  def rm(uri) do
    with {:ok, _segments} <- VikingURI.parse(uri),
         :ok <- Runtime.storage().remove_subtree(uri) do
      Cache.invalidate_removal(uri)
      :ok
    else
      {:error, _} = err -> err
    end
  end

  # -- reading through the cache --

  # The cache answers only from what the store has already committed, and a
  # write drops the entries it affects as it lands, so a cached read and a cold
  # one cannot disagree. A miss rebuilds from storage.
  defp fetch(segments) do
    uri = VikingURI.build(segments)

    case Cache.get_node(uri) do
      {:ok, node} ->
        {:ok, node}

      :miss ->
        case Runtime.storage().get_node(uri) do
          {:ok, nil} -> {:error, :not_found}
          {:ok, node} -> cache_and_return(uri, node)
          {:error, _} = err -> err
        end
    end
  end

  defp cache_and_return(uri, node) do
    :ok = Cache.put_node(uri, node)
    {:ok, node}
  end
end
