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
          updated_at: integer()
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
  # staleness exacts a small penalty. Kept in lockstep with the eval fixture's
  # weights (see `test/support/memory_ranking_fixture.ex`), where the numbers
  # justify them: blended recall@1 1.0 vs similarity-only 0.95 vs
  # confidence-only 0.05.
  @blend_confidence 0.5
  @blend_similarity 0.5
  @blend_exact_boost 0.15
  @blend_decay_penalty 0.1
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
  @spec blend_weights() :: {float(), float(), float(), float()}
  def blend_weights,
    do: {@blend_confidence, @blend_similarity, @blend_exact_boost, @blend_decay_penalty}

  @doc false
  @spec blend_score(float(), float(), boolean()) :: float()
  def blend_score(confidence, sim01, exact?), do: blend_score(confidence, sim01, exact?, 0.0)

  @doc false
  @spec blend_score(float(), float(), boolean(), float()) :: float()
  def blend_score(confidence, sim01, exact?, staleness01) do
    @blend_confidence * confidence + @blend_similarity * sim01 +
      if(exact?, do: @blend_exact_boost, else: 0.0) -
      @blend_decay_penalty * staleness01
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
         status <- gate_status(value, confidence, opts),
         :ok <-
           Runtime.storage().put_memory(uri, value, confidence, source,
             importance: importance,
             status: status
           ) do
      Cache.invalidate_write(uri)
      Runtime.storage().enqueue_job(:embed, %{uri: uri, content: value})
      {:ok, uri}
    end
  end

  # The rule-based gate: explicit opt-in, near-zero confidence, or a value
  # already held elsewhere all wait as candidates. Rule-based and model-free,
  # so recording still needs no model; the reason is debug-logged as a bounded
  # kind, not stored, and the URI is never logged.
  # The duplicate lookup fails open: a store that cannot answer still records.
  defp gate_status(value, confidence, opts) do
    if Keyword.get(opts, :candidate, false) do
      :candidate
    else
      gate_by_rules(value, confidence)
    end
  end

  defp gate_by_rules(value, confidence) do
    cond do
      confidence < @candidate_min_confidence ->
        Observability.log(:debug,
          component: :memory,
          operation: :remember,
          outcome: :held,
          kind: :low_confidence
        )

        :candidate

      duplicate_value?(value) ->
        Observability.log(:debug,
          component: :memory,
          operation: :remember,
          outcome: :held,
          kind: :duplicate
        )

        :candidate

      true ->
        :active
    end
  end

  defp duplicate_value?(value) do
    case Runtime.storage().recall_memories(root_uri(), value, [:active]) do
      {:ok, rows} -> Enum.any?(rows, &(&1.value == value))
      {:error, _} -> false
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
  Results are ordered by descending confidence, and a recall matching nothing
  returns `{:ok, []}` rather than an error. Every returned row is recorded as
  surfaced, so a later inspection reports when it was last seen; a recall that
  fails to record surfacing still returns its rows.

  Each entry carries `:id`, `:uri`, `:value`, `:type`, `:confidence`,
  `:importance`, `:source`, `:status`, `:supersedes`, `:last_surfaced_at` and
  `:updated_at`. With `include_superseded: true`, a superseded entry's
  `:supersedes` is the `:id` of the assertion that replaced it, so the chain
  can be walked from either end.
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

    with {:ok, scope} <- recall_scope(opts) do
      case Runtime.storage().recall_memories(scope, term, statuses) do
        {:ok, rows} ->
          rows = filter_disabled(rows, opts)
          # Ranked before the touch, so a recency-aware rank reads the times
          # as they were when the caller last saw them, not as of this call.
          ranked = rerank_by_term(rows, scope, term, statuses)
          touch_surfaced(ranked)
          {:ok, Enum.map(ranked, &entry(&1, opts))}

        {:error, _} = err ->
          err
      end
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
  # firmly-held fact instead of only what contains the literal substring.
  defp rerank_by_term(rows, _scope, nil, _statuses), do: rows

  defp rerank_by_term(rows, scope, term, statuses) when is_binary(term) do
    candidates =
      if rows == [] do
        broad_candidates(scope, statuses, term)
      else
        rows
      end

    case candidates do
      [] -> []
      _ -> blend_or_fallback(candidates, term)
    end
  end

  # The strict substring gate found nothing: broaden to the active set in
  # scope sharing at least one token with the term, so a paraphrase still has
  # candidates to rank. A term sharing no token with anything still matches
  # nothing, preserving the empty result.
  defp broad_candidates(scope, statuses, term) do
    case Runtime.storage().recall_memories(scope, nil, statuses) do
      {:ok, rows} -> token_overlap(rows, term)
      {:error, _} -> []
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

  # One batched embed for the query plus every candidate value: the filtered
  # set is small (dozens), so exhaustive re-rank is cheap and needs no index.
  # Any failure -- unavailable model, timeout, dim mismatch -- falls back to
  # the storage order with a debug log, so recall never fails for want of an
  # embedding.
  defp blend_or_fallback(candidates, term) do
    if embed_ready?() do
      case Runtime.inference().embed([term | Enum.map(candidates, & &1.value)]) do
        {:ok, [query | vecs]} when length(vecs) == length(candidates) ->
          blend_or_fallback(candidates, term, query, vecs)

        {:ok, _} ->
          Observability.log(:debug,
            component: :memory,
            operation: :recall,
            outcome: :fallback,
            reason: :malformed_embed_batch
          )

          candidates

        {:error, reason} ->
          Observability.log(:debug,
            component: :memory,
            operation: :recall,
            outcome: :fallback,
            reason: reason
          )

          candidates
      end
    else
      candidates
    end
  end

  defp blend_or_fallback(candidates, term, query, vecs) do
    if Enum.all?(vecs, &(byte_size(&1) == byte_size(query))) do
      rank_blended(candidates, term, query, vecs)
    else
      Observability.log(:debug,
        component: :memory,
        operation: :recall,
        outcome: :fallback,
        reason: :dim_mismatch
      )

      candidates
    end
  end

  defp rank_blended(candidates, term, query, vecs) do
    needle = String.downcase(term)
    now = System.system_time(:millisecond)

    candidates
    |> Enum.zip(vecs)
    |> Enum.map(fn {row, vec} ->
      sim01 = (cosine(query, vec) + 1.0) / 2.0
      exact? = String.contains?(String.downcase(row.value), needle)
      {blend_score(row.confidence, sim01, exact?, staleness(row[:last_surfaced_at], now)), row}
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
      Runtime.storage().memory_conflict_pairs(scope)
    end
  end

  @doc """
  Candidates waiting for promotion review, beneath a URI, type, or the whole
  memories root. The same entry shape as `recall/1`.
  """
  @spec pending_candidates(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def pending_candidates(opts \\ []) do
    with {:ok, scope} <- recall_scope(opts) do
      case Runtime.storage().recall_memories(scope, nil, [:candidate]) do
        {:ok, rows} ->
          touch_surfaced(rows)
          {:ok, Enum.map(rows, &entry(&1, opts))}

        {:error, _} = err ->
          err
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
    segments = elem(VikingURI.parse(uri), 1)

    if Enum.take(segments, length(@root)) == @root do
      :ok
    else
      {:error, {:not_a_memory_uri, uri}}
    end
  end

  defp root_uri, do: VikingURI.build(@root)

  # `-- type` is reported rather than stored, because it is a fact about where
  # the memory is filed, and re-deriving it here keeps the reported type from
  # ever disagreeing with the URI. A NULL importance (rows predating the
  # column) reads as the documented default; a NULL surfaced time stays NULL
  # ("never surfaced"), which ranks as maximally stale.
  defp entry(row, opts) do
    type = type_from(opts[:uri] || row.uri)

    Map.take(row, [
      :id,
      :uri,
      :value,
      :confidence,
      :source,
      :status,
      :supersedes,
      :updated_at,
      :last_surfaced_at
    ])
    |> Map.put(:type, type)
    |> Map.put(:importance, row[:importance] || @default_importance)
  end

  defp type_from(uri) do
    uri |> VikingURI.parse() |> elem(1) |> Enum.at(length(@root))
  end
end
