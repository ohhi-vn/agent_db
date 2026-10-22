defmodule AgentDb.Application.Memories do
  @moduledoc false

  # Durable, typed facts an agent holds about its user and its work.
  #
  # A memory is an ordinary document with an assertion behind it, and the
  # assertion -- not the document -- is the memory. That is what makes a
  # revised belief resolvable: the URI says which thing is being asserted, the
  # assertions say what has been held about it, and supersession says which of
  # them is current.
  #
  # No model is involved in any of this. The value of a memory is what it says,
  # and the summaries in this store exist to compress a document too large to
  # read whole; an atomic fact is neither.

  alias AgentDb.Cache
  alias AgentDb.Observability
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @type uri :: String.t()
  @type value :: String.t()
  @type type :: String.t()
  @type entry :: %{
          id: integer(),
          uri: uri(),
          value: value(),
          type: type(),
          confidence: float(),
          importance: float(),
          source: String.t() | nil,
          status: :active | :superseded | :candidate,
          supersedes: integer() | nil,
          last_surfaced_at: integer() | nil,
          truncated: boolean() | nil,
          updated_at: integer(),
          semantic_ranked: boolean()
        }

  # Memories live in a reserved subtree, and a memory's type is the first
  # segment beneath it. Deriving the type from the URI rather than accepting it
  # as an option is what keeps a memory an ordinary document: recall by type is
  # then a prefix query, and a memory's stated type can never contradict where
  # it is filed.
  @root ["user", "memories"]
  @types ~w(profile preferences entities events experiences)
  @default_confidence 0.5
  @default_importance 0.5

  # Below this confidence a record is noise rather than a belief: it waits as
  # a candidate for promotion instead of ranking beside held facts. Lower
  # than any confidence the existing suites record as active (0.2), so the
  # gate only ever catches records that previously read as near-zero beliefs.
  @candidate_min_confidence 0.1

  # Blend weights for term recall: confidence carries provenance, similarity
  # carries phrasing relevance, an exact substring match gets a boost, and
  # staleness exacts a small penalty. Importance sways the order of
  # near-equals: at the staleness penalty's scale it can reorder rows the
  # other terms hold equal, without outmuscling a real paraphrase. Kept in
  # lockstep with the eval fixture's weights (see
  # `test/support/memory_ranking_fixture.ex`), where the numbers justify
  # them: blended recall@1 1.0 vs similarity-only 0.95 vs confidence-only
  # 0.05.
  @blend_confidence 0.5
  @blend_similarity 0.5
  @blend_exact_boost 0.15
  @blend_decay_penalty 0.1
  @blend_importance 0.1
  # Past this age a memory counts as fully stale. Thirty days: long enough
  # that daily-use facts never feel it, short enough that abandoned ones do.
  @stale_after_ms 30 * 24 * 60 * 60 * 1_000

  @doc "The memory types, for callers that need to enumerate the taxonomy."
  @spec types() :: [type()]
  def types, do: @types

  @doc "The confidence recorded when a caller supplies none."
  @spec default_confidence() :: float()
  def default_confidence, do: @default_confidence

  @doc "The importance recorded when a caller supplies none."
  @spec default_importance() :: float()
  def default_importance, do: @default_importance

  @doc false
  @spec blend_weights() :: {float(), float(), float(), float(), float()}
  def blend_weights,
    do: {
      @blend_confidence,
      @blend_similarity,
      @blend_exact_boost,
      @blend_decay_penalty,
      @blend_importance
    }

  # The largest `:top_k` a recall may ask for. Matches the bound the storage
  # read enforces; documented alongside it.
  @max_top_k 500

  @doc false
  @spec blend_score(float(), float(), boolean()) :: float()
  def blend_score(confidence, sim01, exact?), do: blend_score(confidence, sim01, exact?, 0.0)

  @doc false
  @spec blend_score(float(), float(), boolean(), float()) :: float()
  def blend_score(confidence, sim01, exact?, staleness01),
    do: blend_score(confidence, sim01, exact?, staleness01, @default_importance)

  @doc false
  @spec blend_score(float(), float(), boolean(), float(), float()) :: float()
  def blend_score(confidence, sim01, exact?, staleness01, importance) do
    @blend_confidence * confidence + @blend_similarity * sim01 +
      if(exact?, do: @blend_exact_boost, else: 0.0) -
      @blend_decay_penalty * staleness01 +
      @blend_importance * importance
  end

  @doc false
  @spec staleness(integer() | nil, integer()) :: float()
  def staleness(last_surfaced_at, now_ms \\ System.system_time(:millisecond))

  # Never surfaced ranks as maximally stale -- honest, since it is.
  def staleness(nil, _now_ms), do: 1.0

  def staleness(last_surfaced_at, now_ms) do
    min(1.0, max(0.0, (now_ms - last_surfaced_at) / @stale_after_ms))
  end

  @doc false
  @spec cosine(binary(), binary()) :: float()
  def cosine(a, b)
      when is_binary(a) and is_binary(b) and byte_size(a) > 0 and
             byte_size(a) == byte_size(b) and rem(byte_size(a), 4) == 0 do
    xs = for <<x::float-32 <- a>>, do: x
    ys = for <<y::float-32 <- b>>, do: y
    dot = Enum.zip(xs, ys) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    nx = :math.sqrt(Enum.map(xs, &(&1 * &1)) |> Enum.sum())
    ny = :math.sqrt(Enum.map(ys, &(&1 * &1)) |> Enum.sum())

    if nx == 0.0 or ny == 0.0, do: 0.0, else: dot / (nx * ny)
  end

  def cosine(_, _), do: 0.0

  @doc """
  Records a durable fact at `uri`, which must sit beneath
  `viking://user/memories/<type>/`.

  The URI is the identity of the thing being asserted, so recording where a
  memory already exists revises it: the prior value is kept as superseded and
  linked to the assertion that replaced it. Recording where nothing exists
  creates it.

  Enqueues embedding generation and no summarization. The embedding is what
  makes a memory reachable by meaning rather than by the words it happens to
  contain; a summary could say nothing about an atomic fact its value does not
  already say.

  Options:
    - `:confidence` - how firmly the fact is held, 0.0..1.0 (default #{@default_confidence})
    - `:importance` - how much the fact matters, 0.0..1.0 (default #{@default_importance})
    - `:source` - provenance, e.g. the originating session id
    - `:candidate` - record as a candidate awaiting promotion instead of active
      (default `false`)

  Returns `{:ok, uri}`, or an error naming the invalid type
  (`{:error, {:invalid_memory_type, type}}`), a URI outside the memories root
  (`{:error, {:not_a_memory_uri, uri}}`), or `{:error, :invalid_uri}`.
  """
  @spec remember(uri(), value(), keyword()) :: {:ok, uri()} | {:error, term()}
  def remember(uri, value, opts \\ []) when is_binary(value) do
    confidence = Keyword.get(opts, :confidence, @default_confidence)
    importance = Keyword.get(opts, :importance, @default_importance)
    source = Keyword.get(opts, :source)

    with {:ok, uri} <- validate_slot(uri),
         :ok <- validate_confidence(confidence),
         :ok <- validate_importance(importance),
         status <- gate_status(confidence, opts),
         :ok <-
           Runtime.storage().put_memory(uri, value, confidence, source,
             importance: importance,
             status: status,
             jobs: [{:embed, %{uri: uri, content: value}}]
           ) do
      Cache.invalidate_write(uri)
      {:ok, uri}
    end
  end

  # The rule-based gate: an explicit opt-in, or a near-zero confidence, wait as
  # candidates. Rule-based and model-free, so recording still needs no model;
  # the reason is debug-logged as a bounded kind, not stored, and the URI is
  # never logged.
  #
  # The gate does not compare the incoming value against values held at other
  # URIs. A fact the agent states in two places is two facts at two places,
  # and holding the second one back makes it invisible to recall without
  # telling the caller it was held back. Redundancy across URIs is surfaced
  # by the conflict read instead, which reports it without hiding either.
  defp gate_status(confidence, opts) do
    if Keyword.get(opts, :candidate, false) do
      :candidate
    else
      gate_by_rules(confidence)
    end
  end

  defp gate_by_rules(confidence) do
    if confidence < @candidate_min_confidence do
      Observability.log(:debug,
        component: :memory,
        operation: :remember,
        outcome: :held,
        kind: :low_confidence
      )

      :candidate
    else
      :active
    end
  end

  @doc """
  Reads memories back. Accepts a URI directly, or options:

    - `:uri` - recall one memory or a subtree
    - `:type` - recall a whole type, e.g. `:events`
    - `:term` - restrict to memories whose value contains this substring
    - `:top_k` - the bound this recall materialises, 1..#{@max_top_k},
      defaulting to the storage read's own bound of #{@max_top_k}. Out of
      range is `{:error, {:invalid_limit, value}}`, never a substituted bound.
    - `:source` - restrict to memories recorded from that provenance
    - `:include_superseded` - also return superseded assertions, for inspecting
      how a memory's value changed (default `false`)

  `:uri` and `:type` both scope the recall; when both are given `:uri` wins.
   Without a term results order by descending confidence. With a term they
  order by a blend of confidence, semantic similarity, exact substring
  matching, staleness, and importance (`blend_weights/0` exposes the
  weights). A recall matching nothing returns `{:ok, []}` rather than an
  error, and a recall whose store read cannot be answered reports a
  classified reason rather than an empty result. Every returned row is
  recorded as surfaced, so a later inspection reports when it was last
  seen; a recall that fails to record surfacing still returns its rows.

  Each entry carries `:id`, `:uri`, `:value`, `:type`, `:confidence`,
  `:importance`, `:source`, `:status`, `:supersedes`, `:last_surfaced_at`,
  `:updated_at` and `:truncated` -- whether the bound was reached, the same
  flag on every entry a recall returned. With a term, each entry also carries
  `:semantic_ranked` -- true when the blend was ranked from the candidates'
  stored vectors, false when the recall fell back to confidence order (no
  stored vectors for every candidate, a dimensionality the embedding no
  longer matches, or the model being unavailable). With
  `include_superseded: true`, a superseded entry's `:supersedes` is the
  `:id` of the assertion that replaced it, so the chain can be walked from
  either end.
  """
  @spec recall(uri() | keyword()) :: {:ok, [entry()]} | {:error, term()}
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

    with {:ok, scope} <- recall_scope(opts),
         :ok <- validate_top_k(opts) do
      case Runtime.storage().recall_memories(
             scope,
             term,
             statuses,
             Keyword.take(opts, [:top_k, :source])
           ) do
        {:ok, rows} ->
          rows = filter_disabled(rows, opts)

          # Ranked before the touch, so a recency-aware rank reads the times
          # as they were when the caller last saw them, not as of this call.
          case rerank_by_term(rows, scope, term, statuses) do
            {:error, _} = err ->
              err

            {ranked, semantic_ranked} ->
              touch_surfaced(ranked)
              {:ok, Enum.map(ranked, &entry(&1, semantic_ranked: semantic_ranked))}
          end

        {:error, reason} ->
          # A read the store cannot answer is a classified failure, not an
          # empty result: the two are different facts to a caller.
          {:error, Observability.classify_reason(reason)}
      end
    end
  end

  # The bound is the caller's: the storage read applies it and reports whether
  # it was reached, and an out-of-range value is refused here rather than
  # answered with a substituted bound.
  defp validate_top_k(opts) do
    case Keyword.fetch(opts, :top_k) do
      {:ok, top_k} when is_integer(top_k) and top_k >= 1 and top_k <= @max_top_k ->
        :ok

      {:ok, top_k} ->
        {:error, {:invalid_limit, top_k}}

      :error ->
        :ok
    end
  end

  # Disabled is blocked-from-use: excluded from recall by default, included
  # only with `include_disabled: true`. Fail-open on lookup errors so a
  # transient fault does not hide memories.
  defp filter_disabled(rows, opts) do
    if Keyword.get(opts, :include_disabled, false) do
      rows
    else
      Enum.filter(rows, &enabled_memory?/1)
    end
  end

  defp enabled_memory?(%{uri: uri}) do
    case Runtime.storage().get_node(uri) do
      {:ok, nil} -> true
      {:ok, node} -> Map.get(node, :enabled, true) != false
      {:error, _} -> true
    end
  end

  # Best-effort: surfacing is tracking, not the answer. A store that cannot
  # record it still answers the recall.
  defp touch_surfaced([]), do: :ok

  defp touch_surfaced(rows) do
    case Runtime.storage().mark_memories_surfaced(Enum.map(rows, & &1.id)) do
      :ok ->
        :ok

      {:error, reason} ->
        Observability.log(:debug,
          component: :memory,
          operation: :recall,
          outcome: :error,
          reason: reason
        )

        :ok
    end
  end

  # A recall without a term keeps storage order (confidence, the contract
  # callers already rely on). A recall with a term re-ranks the filtered set
  # by confidence blended with semantic similarity, so a paraphrase finds the
  # firmly-held fact; it also reports whether the blend was applied, because
  # the blend needs the candidates' stored vectors and not every recall has
  # them.
  defp rerank_by_term(rows, _scope, nil, _statuses), do: {rows, false}

  defp rerank_by_term(rows, scope, term, statuses) when is_binary(term) do
    with {:ok, candidates} <- term_candidates(rows, scope, statuses, term) do
      case candidates do
        [] -> {[], false}
        _ -> blend_or_fallback(candidates, term)
      end
    end
  end

  # A strict read that answered keeps its candidates: the widening read exists
  # for a recall that found nothing.
  defp term_candidates([_ | _] = rows, _scope, _statuses, _term), do: {:ok, rows}

  # The strict substring gate found nothing: broaden to the active set in
  # scope sharing at least one token with the term, so a paraphrase still has
  # candidates to rank. A term sharing no token with anything still matches
  # nothing, preserving the empty result. A widened read that fails is a
  # classified error, never an empty list: an empty answer says "no
  # candidates", and a caller cannot tell that apart from a store it cannot
  # read.
  defp term_candidates([], scope, statuses, term) do
    case Runtime.storage().recall_memories(scope, nil, statuses) do
      {:ok, rows} -> {:ok, token_overlap(rows, term)}
      {:error, reason} -> {:error, Observability.classify_reason(reason)}
    end
  end

  defp token_overlap(rows, term) do
    wanted = MapSet.new(tokens(term))

    Enum.filter(rows, fn row ->
      not MapSet.disjoint?(MapSet.new(tokens(row.value)), wanted)
    end)
  end

  defp tokens(text) do
    text |> String.downcase() |> then(&Regex.scan(~r/[a-z0-9]+/, &1)) |> List.flatten()
  end

  # The query is the only inference on the recall path: the candidates'
  # vectors are already stored, and the read path re-embeds nothing. A stored
  # vector for every candidate, all the same size as the query's embedding,
  # ranks the blend; anything less -- a missing vector, a dimensionality the
  # embedding no longer matches, the model being unavailable -- falls back to
  # the storage order with a debug log, so a recall never fails or waits for
  # want of an embedding, and reports that no semantic rank was applied.
  defp blend_or_fallback(candidates, term) do
    if embed_ready?() do
      case Runtime.inference().embed([term]) do
        {:ok, [query]} ->
          rank_stored_or_fallback(candidates, term, query)

        {:ok, _} ->
          fallback(candidates, :malformed_embed_batch)

        {:error, reason} ->
          fallback(candidates, reason)
      end
    else
      {candidates, false}
    end
  end

  defp rank_stored_or_fallback(candidates, term, query) do
    uris = Enum.map(candidates, & &1.uri)

    case Runtime.storage().load_memory_vectors(uris) do
      {:ok, vectors} -> rank_with_stored(candidates, term, query, vectors)
      {:error, reason} -> fallback(candidates, reason)
    end
  end

  # All-or-nothing: ranking a subset would silently change which memories a
  # recall answers with, so the candidates the stored index cannot answer --
  # one absent here, one dimension-mismatched there -- fall back as a set.
  defp rank_with_stored(candidates, term, query, vectors) do
    cond do
      Enum.any?(candidates, &(not Map.has_key?(vectors, &1.uri))) ->
        fallback(candidates, :stored_vectors_incomplete)

      Enum.any?(candidates, &(byte_size(Map.fetch!(vectors, &1.uri)) != byte_size(query))) ->
        fallback(candidates, :dim_mismatch)

      true ->
        vecs = Enum.map(candidates, &Map.fetch!(vectors, &1.uri))
        {rank_blended(candidates, term, query, vecs), true}
    end
  end

  defp fallback(rows, reason) do
    Observability.log(:debug,
      component: :memory,
      operation: :recall,
      outcome: :fallback,
      reason: reason
    )

    {rows, false}
  end

  defp rank_blended(candidates, term, query, vecs) do
    needle = String.downcase(term)
    now = System.system_time(:millisecond)

    candidates
    |> Enum.zip(vecs)
    |> Enum.map(fn {row, vec} ->
      sim01 = (cosine(query, vec) + 1.0) / 2.0
      exact? = String.contains?(String.downcase(row.value), needle)

      # Legacy rows predate the importance column and read as the documented
      # default, so storage never invents a value of its own.
      importance = row[:importance] || @default_importance

      score =
        blend_score(
          row.confidence,
          sim01,
          exact?,
          staleness(row[:last_surfaced_at], now),
          importance
        )

      {score, row}
    end)
    |> Enum.sort_by(fn {score, row} -> {-score, -row.confidence, row.uri, row.id} end)
    |> Enum.map(&elem(&1, 1))
  end

  # Readiness is asked, never triggered: a read path must not start a model
  # load or download. Local reports loaded once retained; remotes report ready
  # when reachable; anything else (idle, loading, failed, unreachable) stays on
  # confidence order.
  defp embed_ready? do
    case Runtime.inference().model_status() do
      %{embedding: %{loaded: true}} -> true
      %{embedding: %{state: :ready}} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Promotes the waiting candidate at `uri` to the active assertion, superseding
  any prior active one. The promoted memory is an ordinary active memory
  afterwards. Returns `{:error, :no_candidate}` when none is waiting.
  """
  @spec promote(uri()) :: {:ok, uri()} | {:error, term()}
  def promote(uri) do
    with {:ok, _segments} <- VikingURI.parse(uri),
         {:ok, :promoted} <- Runtime.storage().promote_memory(uri) do
      Cache.invalidate_write(uri)
      {:ok, uri}
    end
  end

  @doc """
  Rejects the waiting candidate at `uri`, removing it without a trace: no
  value, provenance, or history remains that was only ever a candidate. An
  active belief at the same URI is untouched. Returns
  `{:error, :no_candidate}` when none is waiting.
  """
  @spec reject_candidate(uri()) :: :ok | {:error, term()}
  def reject_candidate(uri) do
    with {:ok, _segments} <- VikingURI.parse(uri),
         :ok <- Runtime.storage().reject_memory_candidate(uri) do
      Cache.invalidate_removal(uri)
      :ok
    end
  end

  @doc """
  Pairs of active memories beneath a URI, type, or the whole memories root
  whose values are similar enough to be possible conflicts. Read-only: nothing
  is resolved, merged, or modified. `{:error, :embeddings_unavailable}` when
  stored vectors cannot evaluate them.
  """
  @spec conflicts(keyword()) :: {:ok, [map()]} | {:error, term()}
  def conflicts(opts \\ []) do
    with {:ok, scope} <- recall_scope(opts) do
      case Runtime.storage().memory_conflict_pairs(scope) do
        {:ok, pairs} ->
          {:ok, pairs}

        {:error, reason} ->
          # `:embeddings_unavailable` classifies to itself, so the
          # unevaluable verdict survives verbatim; anything the store
          # could not answer is flattened to its bounded tag.
          {:error, Observability.classify_reason(reason)}
      end
    end
  end

  @doc """
  Counts of memories per type and per status, the number waiting for review,
  and the number never surfaced, computed by the store without materialising
  every memory.
  """
  @spec statistics() :: {:ok, map()} | {:error, term()}
  def statistics do
    case Runtime.storage().memory_stats() do
      {:ok, stats} -> {:ok, stats}
      {:error, reason} -> {:error, Observability.classify_reason(reason)}
    end
  end

  @doc "Alias for `statistics/0`."
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats, do: statistics()

  @doc "Alias for `statistics/0`."
  @spec memory_stats() :: {:ok, map()} | {:error, term()}
  def memory_stats, do: statistics()
  @spec pending_candidates(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def pending_candidates(opts \\ []) do
    with {:ok, scope} <- recall_scope(opts) do
      case Runtime.storage().recall_memories(scope, nil, [:candidate]) do
        {:ok, rows} ->
          touch_surfaced(rows)
          {:ok, Enum.map(rows, &entry(&1, opts))}

        {:error, reason} ->
          # Same discipline as recall: a read that fails is classified, not
          # an empty review backlog.
          {:error, Observability.classify_reason(reason)}
      end
    end
  end

  @doc """
  Removes the memory at `uri` along with its provenance: its value, every
  assertion recorded there including superseded ones, and its document.

  Supersession, not forgetting, is what preserves history; a tombstone that
  kept the text would not have forgotten anything. A URI holding only an
  ordinary document is left alone.

  Returns `:ok`, or `{:error, :no_memory}` when no memory is recorded there.
  """
  @spec forget(uri()) :: :ok | {:error, term()}
  def forget(uri) do
    with {:ok, _segments} <- VikingURI.parse(uri) do
      forget_recorded(uri)
    end
  end

  # The same removal any document gets, rather than a memory-specific delete: a
  # memory is an ordinary document with an assertion behind it, and the
  # assertion rows are keyed by URI like everything else. That is what keeps a
  # forgotten memory from leaving text behind.
  defp forget_recorded(uri) do
    case Runtime.storage().memory_recorded?(uri) do
      {:ok, true} -> remove(uri)
      {:ok, false} -> {:error, :no_memory}
      {:error, _} = err -> err
    end
  end

  defp remove(uri) do
    case Runtime.storage().remove_subtree(uri) do
      :ok ->
        Cache.invalidate_removal(uri)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # -- validation --

  defp validate_slot(uri) do
    case VikingURI.parse(uri) do
      {:ok, [_user, "memories", type | rest]} when rest != [] ->
        if type in @types, do: {:ok, uri}, else: {:error, {:invalid_memory_type, type}}

      {:ok, _other} ->
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

  defp validate_importance(importance) when is_number(importance) do
    if importance >= 0.0 and importance <= 1.0 do
      :ok
    else
      {:error, {:invalid_importance, importance}}
    end
  end

  defp validate_importance(importance), do: {:error, {:invalid_importance, importance}}

  # `:uri` scopes directly and `:type` scopes to that type's subtree; neither
  # scopes to the whole memories root. The store matches a scope as
  # exact-uri-or-descendant, so no trailing separator is involved and a scope of
  # `.../preferences` cannot reach a sibling `preferences-extra`.
  defp recall_scope(opts) do
    case {Keyword.get(opts, :uri), Keyword.get(opts, :type)} do
      {nil, nil} ->
        {:ok, root_uri()}

      {uri, _type} when is_binary(uri) ->
        with :ok <- validate_memory_scope(uri), do: {:ok, uri}

      {nil, type} ->
        with {:ok, type} <- validate_type(type), do: {:ok, root_uri() <> "/" <> type}

      {_uri, type} ->
        # An explicit URI already fixes the scope, so the type only has to be
        # one this store recognises: a typo is reported rather than ignored.
        validate_type(type)
    end
  end

  # A type arrives either as a URI segment or as an option a caller naturally
  # writes as an atom. Both resolve to the segment form, which is what the URI
  # and the taxonomy actually speak.
  defp validate_type(type) when is_atom(type) and not is_nil(type) do
    validate_type(Atom.to_string(type))
  end

  defp validate_type(type) when is_binary(type) do
    if type in @types, do: {:ok, type}, else: {:error, {:invalid_memory_type, type}}
  end

  defp validate_type(type), do: {:error, {:invalid_memory_type, type}}

  defp validate_memory_scope(uri) do
    case VikingURI.parse(uri) do
      {:ok, segments} ->
        if Enum.take(segments, length(@root)) == @root do
          :ok
        else
          {:error, {:not_a_memory_uri, uri}}
        end

      {:error, :invalid_uri} ->
        {:error, :invalid_uri}
    end
  end

  defp root_uri, do: VikingURI.build(@root)

  # `-- type` is reported rather than stored, because it is a fact about where
  # the memory is filed, and re-deriving it here keeps the reported type from
  # ever disagreeing with the URI. The type comes from the memory's own URI and
  # not from the scope the recall was issued against: the scope is the question
  # being asked, and the answer is where each memory is filed. A NULL
  # importance (rows predating the column) reads as the documented default; a
  # NULL surfaced time stays NULL ("never surfaced"), which ranks as maximally
  # stale.
  defp entry(row, opts) do
    type = type_from(row.uri)

    Map.take(row, [
      :id,
      :uri,
      :value,
      :confidence,
      :source,
      :status,
      :supersedes,
      :updated_at,
      :last_surfaced_at,
      :truncated
    ])
    |> Map.put(:type, type)
    |> Map.put(:importance, row[:importance] || @default_importance)
    # Everything that falls back to confidence order reads the same way: the
    # flag says the blend was not applied, and says nothing about why.
    |> Map.put(:semantic_ranked, Keyword.get(opts, :semantic_ranked, false))
  end

  defp type_from(uri) do
    case VikingURI.parse(uri) do
      {:ok, segments} -> Enum.at(segments, length(@root))
      {:error, :invalid_uri} -> nil
    end
  end
end
