defmodule AgentDb.Application.Documents do
  @moduledoc false

  # Writing, reading and removing documents, and the tree they form.
  #
  # Every call reaches the store through the storage port, and answers in the
  # terms the port speaks: URIs in, nodes and results out. What this workflow
  # owns is what those answers mean -- which layer a read resolves to when the
  # stored one is missing, how a write acknowledges, when a write is complete
  # -- and none of how any of it is stored.

  alias AgentDb.Application.Navigation
  alias AgentDb.Cache
  alias AgentDb.Observability
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
    Observability.with_correlation(trace_correlation(opts), fn ->
      Observability.timed(:write, %{}, fn ->
        Observability.with_span("agent_db.write", %{}, fn -> do_write(uri, content, opts) end)
      end)
    end)
  end

  # The incoming trace, when there is one, so the operation's logs and the jobs
  # it enqueues carry the same trace id.
  defp trace_correlation(opts) do
    case Keyword.get(opts, :trace_context) do
      %{trace_id: trace_id, span_id: span_id} when is_binary(trace_id) and is_binary(span_id) ->
        %{trace_id: trace_id, span_id: span_id}

      _ ->
        %{}
    end
  end

  defp do_write(uri, content, opts) do
    async = Keyword.get(opts, :async, AgentDb.Config.async_writes())

    with {:ok, segments} <- VikingURI.parse(uri),
         jobs = jobs_for(uri, content, opts),
         :ok <- persist(segments, content, opts, jobs) do
      Cache.invalidate_write(uri)

      if async do
        :ok
      else
        settle(uri, opts)
      end
    else
      :root -> {:error, :is_root}
      {:error, _} = err -> err
    end
  end

  defp persist(segments, content, opts, jobs) do
    Runtime.storage().put_document(
      VikingURI.build(segments),
      content,
      Keyword.put(opts, :jobs, jobs)
    )
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

  defp jobs_for(uri, content, opts) do
    base = %{uri: uri, content: content}

    payload =
      case Keyword.get(opts, :trace_context) do
        %{trace_id: _, span_id: _} = ctx ->
          Map.put(base, "_trace", %{trace_id: ctx.trace_id, span_id: ctx.span_id})

        _ ->
          base
      end

    Enum.map(kinds_for(opts), &{&1, payload})
  end

  # A synchronous caller is told which of three things happened. The pending
  # count once excluded failed rows, so a job that died on its first attempt
  # read as an idle queue and the write reported success having done nothing.
  defp settle(uri, opts) do
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
    Observability.timed(:read, %{}, fn ->
      with {:ok, segments} <- VikingURI.parse(uri) do
        layer(segments, & &1.content)
      end
    end)
  end

  @doc """
  Reads the L0 abstract, falling back to frontmatter identity or the first
  non-empty body line.

  The fallback is what makes a document readable at all when no model is
  available, so it is a value the store always has rather than an error the
  caller has to handle.
  """
  @spec abstract(uri()) :: {:ok, content()} | {:error, term()}
  def abstract(uri) do
    Observability.timed(:abstract, %{}, fn ->
      with {:ok, segments} <- VikingURI.parse(uri) do
        layer(segments, fn node -> node.abstract || fallback_abstract(node.content) end)
      end
    end)
  end

  @doc "Reads the L1 overview, falling back to the first 280 characters of the body after frontmatter."
  @spec overview(uri()) :: {:ok, content()} | {:error, term()}
  def overview(uri) do
    Observability.timed(:overview, %{}, fn ->
      with {:ok, segments} <- VikingURI.parse(uri) do
        layer(segments, fn node -> node.overview || fallback_overview(node.content) end)
      end
    end)
  end

  @doc """
  Reads the stored L0/L1 layers without fallback.

  Returns `{:ok, %{abstract: binary | nil, overview: binary | nil}}` for a
  stored document, so a caller can tell a stored layer from a fallback-derived
  one without reimplementing the fallback. A missing URI returns an error.
  """
  @spec stored_layers(uri()) ::
          {:ok, %{abstract: content() | nil, overview: content() | nil}} | {:error, term()}
  def stored_layers(uri) do
    Observability.timed(:stored_layers, %{}, fn ->
      with {:ok, segments} <- VikingURI.parse(uri),
           {:ok, node} <- fetch(segments) do
        {:ok, %{abstract: node.abstract, overview: node.overview}}
      end
    end)
  end

  defp layer(segments, select) do
    with {:ok, node} <- fetch(segments) do
      {:ok, select.(node) || ""}
    end
  end

  defp first_line(content),
    do: content |> String.split("\n") |> Enum.find("", &(&1 != "")) |> String.trim()

  defp first_chars(content), do: String.slice(content, 0, 280)

  # -- frontmatter-aware fallbacks --

  # A SKILL.md (or any document) may start with a YAML frontmatter block whose
  # first line is `---` and whose identity no reader should ever see as the
  # abstract. The fallback therefore prefers the parsed `name:`/`description:`
  # identity and otherwise derives from the body after the closing delimiter.
  defp fallback_abstract(nil), do: ""

  defp fallback_abstract(content) do
    case split_frontmatter(content) do
      {:ok, fields, body} ->
        case frontmatter_identity(fields) do
          nil -> first_line(body)
          identity -> identity
        end

      :none ->
        first_line(content)
    end
  end

  defp fallback_overview(nil), do: ""

  defp fallback_overview(content) do
    case split_frontmatter(content) do
      {:ok, _fields, body} -> body |> String.trim_leading() |> String.slice(0, 280)
      :none -> first_chars(content)
    end
  end

  # Only a leading `---` line opens frontmatter, and only a later `---`-only
  # line within the header window closes it. Anything else -- an unclosed
  # delimiter, a `---` separator mid-document, a block with no `key: value`
  # line -- is plain body, so today's fallback applies unchanged.
  @frontmatter_window 20

  defp split_frontmatter(content) when is_binary(content) do
    normalized =
      content
      |> String.replace_prefix("\uFEFF", "")
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    case String.split(normalized, "\n") do
      [first | rest] when rest != [] ->
        if String.trim(first) == "---" do
          split_at_closing(rest)
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp split_at_closing(rest) do
    window = Enum.take(rest, @frontmatter_window)

    case Enum.find_index(window, &(String.trim(&1) == "---")) do
      nil ->
        :none

      index ->
        fields = Enum.take(window, index)

        if Enum.any?(fields, &key_value_line?/1) do
          body = rest |> Enum.drop(index + 1) |> Enum.join("\n")
          {:ok, fields, body}
        else
          :none
        end
    end
  end

  defp key_value_line?(line), do: line =~ ~r/^\s*[A-Za-z0-9_-]+\s*:/

  defp frontmatter_identity(fields) do
    case {frontmatter_field(fields, "name"), frontmatter_field(fields, "description")} do
      {nil, nil} -> nil
      {name, nil} -> truncate_identity(name)
      {nil, description} -> truncate_identity(description)
      {name, description} -> truncate_identity(name <> " — " <> description)
    end
  end

  # An abstract stays scannable: one line, bounded like the L1 fallback.
  defp truncate_identity(identity), do: String.slice(identity, 0, 280)

  # First occurrence wins. An empty value takes the first following non-empty
  # line that is not itself a `key: value` line, which covers folded
  # continuations without a YAML parser.
  defp frontmatter_field(fields, key) do
    fields
    |> Enum.with_index()
    |> Enum.find_value(fn {line, index} ->
      case parse_field_line(line, key) do
        :no_match -> nil
        {:value, ""} -> fields |> Enum.drop(index + 1) |> Enum.find_value(&continuation_line/1)
        {:value, value} -> value
      end
    end)
  end

  defp continuation_line(line) do
    cond do
      String.trim(line) == "" -> nil
      key_value_line?(line) -> nil
      true -> String.trim(line)
    end
  end

  defp parse_field_line(line, key) do
    case Regex.run(~r/^\s*#{key}\s*:(.*)$/, line) do
      [_, raw] -> {:value, raw |> String.trim() |> unquote_scalar()}
      nil -> :no_match
    end
  end

  defp unquote_scalar(value) do
    if String.length(value) >= 2 and quoted?(value) do
      value |> String.slice(1, String.length(value) - 2) |> String.trim()
    else
      value
    end
  end

  defp quoted?(value),
    do:
      (String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
        (String.starts_with?(value, "'") and String.ends_with?(value, "'"))

  @doc "Lists the names of a URI's direct children, and only those."
  @spec list(uri()) :: {:ok, [String.t()]} | {:error, term()}
  def list(uri) do
    Observability.timed(:list, %{}, fn -> list_cached(uri) end)
  end

  # A listing is cached the same way a node is, because a tree projection lists
  # every node it visits: without this, projecting a subtree of N nodes cost N
  # listing queries, most of which asked a document for children it does not
  # have.
  #
  # Both answers are cached. `:not_found` is a real answer here -- it is what a
  # document and a missing URI both return -- and caching it is what stops the
  # projection from re-asking for the same empty listing on every call.
  #
  # Invalidation is the cache's existing job: every path that changes a
  # listing's membership -- a write, a subtree removal, a session commit, a
  # memory recorded or forgotten, a skill import -- already drops the parent
  # and every ancestor's entry, and a background result never changes names.
  defp list_cached(uri) do
    case Cache.get_dir(uri) do
      {:ok, cached} ->
        cached

      :miss ->
        case list_uncached(uri) do
          {:ok, _names} = result ->
            Cache.put_dir(uri, result)
            result

          {:error, :not_found} = result ->
            Cache.put_dir(uri, result)
            result

          {:error, _} = result ->
            # A failure that says nothing about membership -- an unreachable
            # database, say -- is not cached, so a transient fault does not
            # outlive it.
            result
        end
    end
  end

  defp list_uncached(uri) do
    case VikingURI.parse(uri) do
      {:ok, segments} -> Runtime.storage().list_children(VikingURI.build(segments))
      {:error, _} = err -> err
    end
  end

  @default_find_limit 50
  @max_find_limit 200
  @max_query_length 256

  @doc """
  Discovers files and directories whose URI path contains `query`.

  `query` is a non-empty literal substring of at most 256 characters,
  matched case-insensitively over the URI path (excluding the `viking://`
  scheme). SQL wildcards and regular-expression metacharacters match
  literally.

  Options:
    - `:scope` - a URI; only the scope node and its descendants match
    - `:limit` - maximum results (default 50, maximum 200)

  Results are ordered by URI without document content, and an empty match
  is `{:ok, []}` rather than an error.
  """
  @spec find(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def find(query, opts \\ []) do
    Observability.timed(:find, %{}, fn ->
      with :ok <- Navigation.validate_query(query, @max_query_length),
           {:ok, limit} <- Navigation.validate_limit(opts, @default_find_limit, @max_find_limit),
           {:ok, scope_uri} <- Navigation.validate_scope(opts) do
        fetch_limit = min(limit * 3, @max_find_limit)

        case Runtime.storage().find_paths(query, scope_uri, fetch_limit) do
          {:ok, hits} ->
            hits =
              hits
              |> filter_enabled(opts)
              |> Enum.take(limit)
              |> Enum.map(&Map.drop(&1, [:enabled, :group_tag]))

            {:ok, hits}

          {:error, _} = err ->
            err
        end
      end
    end)
  end

  @doc "A depth-limited projection of the tree at `uri` (default depth 2)."
  @spec tree(uri(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def tree(uri, depth \\ 2)

  def tree(uri, depth) when is_integer(depth) and depth >= 1 do
    Observability.timed(:tree, %{}, fn ->
      with {:ok, segments} <- VikingURI.parse(uri),
           {:ok, node} <- fetch_entry(segments) do
        project(segments, node, depth)
      end
    end)
  end

  defp fetch_entry([]), do: {:error, :not_found}
  defp fetch_entry(segments), do: fetch(segments)

  # Depth 1 is the node's own direct children, by name. Deeper is one level of
  # entries, each expanded by the depth that remains.
  #
  # The node's parsed segments travel with the projection rather than being
  # re-parsed from the URI at every level: a projection walks a subtree, so
  # re-parsing made a per-child cost out of work the caller already did.
  defp project(segments, node, depth) do
    case list(node.uri) do
      {:ok, names} -> {:ok, Map.put(entry(node), :children, children(segments, names, depth))}
      {:error, :not_found} -> {:ok, Map.put(entry(node), :children, [])}
      {:error, _} = err -> err
    end
  end

  defp children(_segments, names, 1), do: names

  defp children(segments, names, depth) do
    Enum.map(names, fn name ->
      with {:ok, child_segments} <- VikingURI.join(segments, name),
           {:ok, child_node} <- fetch(child_segments) do
        case project(child_segments, child_node, depth - 1) do
          {:ok, projected} -> projected
          {:error, _} -> entry(child_node)
        end
      else
        # A name listed by a directory that has since lost the node behind it.
        _unreachable -> %{name: name, uri: nil, type: :missing}
      end
    end)
  end

  defp entry(%{kind: :dir} = node), do: %{name: node.name, uri: node.uri, type: :dir}

  defp entry(%{kind: :doc} = node),
    do: %{name: node.name, uri: node.uri, type: :doc, abstract: node.abstract}

  # -- removing --

  @doc "Removes the subtree at `uri`, from every store keyed by URI."
  @spec rm(uri()) :: :ok | {:error, term()}
  def rm(uri) do
    Observability.timed(:rm, %{}, fn ->
      with {:ok, _segments} <- VikingURI.parse(uri),
           :ok <- Runtime.storage().remove_subtree(uri) do
        Cache.invalidate_removal(uri)
        :ok
      else
        {:error, _} = err -> err
      end
    end)
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

  defp filter_enabled(results, opts) do
    if Keyword.get(opts, :include_disabled, false) do
      results
    else
      Enum.filter(results, &(Map.get(&1, :enabled, true) != false))
    end
  end
end
