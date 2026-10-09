defmodule AgentDb.Application.Search do
  @moduledoc false

  # Finding documents: by the words they contain, by what they are about, or by
  # both.
  #
  # The three modes are the same question asked three ways, so they share a
  # scope, a result shape and a top-k. What differs is where the ranking comes
  # from, and which of them can be refused.

  alias AgentDb.Application.Navigation
  alias AgentDb.Observability
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @type mode :: :keyword | :vector | :hybrid
  @type result :: %{
          uri: String.t(),
          content: String.t() | nil,
          abstract: String.t() | nil,
          overview: String.t() | nil,
          score: float()
        }

  @default_top_k 10
  @default_weights {0.5, 0.5}
  # The constant in reciprocal rank fusion. Fixed, not configurable: it damps
  # how much a single rank difference can move a fused score, and a value a
  # caller could set would change ranking for reasons unrelated to the documents.
  @rrf_k 60
  @leg_timeout_ms 10_000

  @doc """
  Searches for `term`.

  Options:
    - `:mode` - `:keyword` (default), `:vector`, or `:hybrid`
    - `:scope` - a URI prefix to limit the search to one subtree
    - `:top_k` - maximum results (default 10)
    - `:hybrid_weights` - `{keyword_weight, vector_weight}` or `[keyword: kw, vector: vw]` (default `{0.5, 0.5}`)

  A leg that cannot be served -- no vector index, or no embedding model -- is
  reported to the caller rather than raised, so a remote client gets an answer
  instead of a dead connection.
  """
  @spec search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def search(term, opts \\ []) do
    # Malformed trace context never rejects: it is ignored and a new trace
    # begins, preserving the existing result contract.
    Observability.with_correlation(trace_context(opts) || %{}, fn ->
      Observability.timed(:search, %{kind: Keyword.get(opts, :mode, :keyword)}, fn ->
        Observability.with_span("agent_db.search", %{}, fn -> do_search(term, opts) end)
      end)
    end)
  end

  defp trace_context(opts) do
    case Keyword.get(opts, :trace_context) do
      %{trace_id: trace_id, span_id: span_id}
      when is_binary(trace_id) and is_binary(span_id) ->
        %{trace_id: trace_id, span_id: span_id}

      _ ->
        nil
    end
  end

  defp do_search(term, opts) do
    # The bound is checked once, here, before a leg is chosen. A leg that
    # validated its own would answer an unusable `:top_k` as whatever that leg
    # failed for instead -- a vector search would report its missing model for a
    # request that was never well formed.
    with {:ok, _limit} <- result_limit(opts) do
      case Keyword.get(opts, :mode, :keyword) do
        # A mode arrives as an atom from a caller, or as the string the wire
        # carries from a transport. Both name the same three modes; anything else
        # is reported as it arrived rather than substituted for, since answering
        # a different question than the one asked is worse than an error.
        mode when mode in ["keyword", :keyword] -> keyword(term, opts)
        mode when mode in ["vector", :vector] -> vector(term, opts)
        mode when mode in ["hybrid", :hybrid] -> hybrid(term, opts)
        other -> {:error, {:invalid_mode, other}}
      end
    end
  end

  @doc "The subtree prefix a search is scoped to, or `{:ok, nil}` for no scope."
  @spec scope_prefix(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def scope_prefix(opts) do
    case Keyword.get(opts, :scope) do
      nil ->
        {:ok, nil}

      uri ->
        with {:ok, segments} <- VikingURI.parse(uri) do
          {:ok, VikingURI.scope_prefix(uri, segments)}
        end
    end
  end

  @default_grep_limit 50
  @max_grep_limit 200
  @max_grep_query_length 256

  @doc """
  Searches full document content (L2) for a literal substring.

  `query` is a non-empty literal of at most 256 characters, matched
  case-insensitively. `%`, `_`, `\\`, and regular-expression metacharacters
  match literally. Abstracts and overviews never match.

  Options:
    - `:scope` - a URI; only the scope node and its descendants match
    - `:limit` - maximum line hits (default 50, maximum 200)

  Each hit carries its document URI, one-based line number, and an excerpt
  of at most 280 characters containing the match. Hits are ordered by URI
  then line number, and an empty match is `{:ok, []}` rather than an error.
  """
  @spec grep(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def grep(query, opts \\ []) do
    Observability.timed(:grep, %{}, fn ->
      with :ok <- Navigation.validate_query(query, @max_grep_query_length),
           {:ok, limit} <-
             Navigation.validate_limit(opts, @default_grep_limit, @max_grep_limit),
           {:ok, scope_uri} <- Navigation.validate_scope(opts) do
        Runtime.storage().grep_content(query, scope_uri, limit)
      end
    end)
  end

  defp keyword(term, opts) do
    mode = Keyword.get(opts, :mode, :keyword)

    Observability.stage(:resource_search, mode, fn ->
      Observability.stage(:intent, mode, fn ->
        Observability.stage(:memory_search, mode, fn ->
          Observability.stage(:skill_retrieval, mode, fn ->
            with {:ok, prefix} <- scope_prefix(opts),
                 {:ok, limit} <- result_limit(opts) do
              # The bound goes down to storage rather than being applied to
              # everything it returned: an unbounded scan materializes every
              # match and then discards all but the first few, which is the
              # whole cost the bound exists to avoid.
              case Runtime.storage().search_keyword(term, prefix, limit) do
                {:ok, nodes} -> {:ok, Enum.map(nodes, &entry/1)}
                {:error, _} = err -> err
              end
            end
          end)
        end)
      end)
    end)
  end

  @max_top_k 200

  # `:top_k` has always been documented as the maximum number of results, and
  # the vector and hybrid legs have always honoured it. The keyword leg did
  # not, so a common term on a large store returned every matching document
  # with its full content -- the same query costing more the more it matched.
  #
  # Out of range is an error rather than a silent fallback: falling back to the
  # default would answer a different question than the one asked, which is
  # what the other validated bounds in this module already refuse to do.
  defp result_limit(opts) do
    case Keyword.get(opts, :top_k, @default_top_k) do
      limit when is_integer(limit) and limit >= 1 and limit <= @max_top_k ->
        {:ok, limit}

      limit when is_integer(limit) ->
        {:error, {:invalid_limit, limit}}

      _other ->
        {:error, {:invalid_limit, Keyword.get(opts, :top_k)}}
    end
  end

  defp vector(term, opts) do
    mode = Keyword.get(opts, :mode, :vector)

    Observability.stage(:embedding, mode, fn ->
      Observability.stage(:resource_search, mode, fn ->
        with {:ok, prefix} <- scope_prefix(opts) do
          case embed_query(term) do
            {:ok, query} ->
              Runtime.storage().search_vector(query, top_k(opts), prefix)

            {:error, _} = err ->
              err
          end
        end
      end)
    end)
  end

  defp embed_query(term) do
    case Runtime.inference().embed([term]) do
      {:ok, [query]} -> {:ok, query}
      {:ok, []} -> {:error, :no_embedding}
      {:error, _} = err -> err
    end
  end

  # Both legs are drained before either is inspected, so a failure in one does
  # not leave the other task's result unread. Timeouts and exits become
  # classified errors instead of exiting the caller, so a WebSocket connection
  # stays usable after a failed hybrid search.
  defp hybrid(term, opts) do
    mode = Keyword.get(opts, :mode, :hybrid)

    Observability.stage(:rerank, mode, fn ->
      Observability.stage(:context_assembly, mode, fn ->
        keyword_task = Task.async(fn -> keyword(term, opts) end)
        vector_task = Task.async(fn -> vector(term, opts) end)

        keyword_result = await_leg(keyword_task, :keyword)
        vector_result = await_leg(vector_task, :vector)

        with {:ok, keyword_results} <- keyword_result,
             {:ok, vector_results} <- vector_result do
          weights = normalize_weights(Keyword.get(opts, :hybrid_weights, @default_weights))
          {:ok, fuse(keyword_results, vector_results, weights) |> Enum.take(top_k(opts))}
        end
      end)
    end)
  end

  defp await_leg(task, leg) do
    case Task.yield(task, @leg_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, {:hybrid_leg_timeout, leg}}

      {:exit, reason} ->
        {:error, {:hybrid_leg_failed, leg, reason}}
    end
  end

  # `hybrid_weights` accepts both `{kw, vw}` tuples and
  # `[keyword: kw, vector: vw]` lists with identical meaning, normalized once
  # here before fusion. Anything else falls back to the default rather than
  # failing the search for a malformed weight.
  defp normalize_weights({kw, vw})
       when (is_number(kw) or is_float(kw) or is_integer(kw)) and
              (is_number(vw) or is_float(vw) or is_integer(vw)) do
    {kw, vw}
  end

  defp normalize_weights(weights) when is_list(weights) do
    {Keyword.get(weights, :keyword, 0.5), Keyword.get(weights, :vector, 0.5)}
  end

  defp normalize_weights(_), do: @default_weights

  # Reciprocal rank fusion: each leg contributes 1/(rank + k), weighted. Ranking
  # is by position within a leg rather than by its score, so a keyword rank and
  # a cosine distance are combined without having to be commensurable. The
  # fused score is put rather than updated: a keyword-only hit carries no score
  # of its own, and fusion must not crash on it.
  defp fuse(keyword_results, vector_results, {keyword_weight, vector_weight}) do
    keyword_ranks = ranks(keyword_results)
    vector_ranks = ranks(vector_results)

    keyword_results
    |> Enum.map(& &1.uri)
    |> Enum.concat(Enum.map(vector_results, & &1.uri))
    |> Enum.uniq()
    |> Enum.map(fn uri ->
      score =
        rank_score(keyword_ranks, uri, keyword_weight) +
          rank_score(vector_ranks, uri, vector_weight)

      Map.put(best(uri, keyword_results, vector_results), :score, score)
    end)
    |> Enum.sort_by(&(-&1.score))
  end

  defp ranks(results) do
    results |> Enum.with_index() |> Map.new(fn {result, index} -> {result.uri, index + 1} end)
  end

  defp rank_score(ranks, uri, weight) do
    case ranks[uri] do
      nil -> 0.0
      rank -> weight * (1.0 / (rank + @rrf_k))
    end
  end

  # A URI found by both legs is one document, reported once, with the data
  # either leg has for it.
  defp best(uri, keyword_results, vector_results) do
    Enum.find(keyword_results, &(&1.uri == uri)) || Enum.find(vector_results, &(&1.uri == uri))
  end

  defp top_k(opts) do
    case Keyword.get(opts, :top_k, @default_top_k) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_top_k
    end
  end

  defp entry(node) do
    %{uri: node.uri, content: node.content, abstract: node.abstract, overview: node.overview}
  end
end
