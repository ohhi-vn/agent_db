defmodule AgentDb.Test.Support.MemoryRankingFixture do
  @moduledoc false
  # Paraphrase eval fixture for memory recall ranking.
  #
  # Twenty memories across the taxonomy with varied confidences, twenty
  # paraphrased queries each expecting one memory, and controlled vectors so
  # similarity is deterministic without a model. Pure helpers rank plain maps,
  # so the fixture runs with no database and no inference.
  #
  # Vectors are 4-lists. Most are spread by construction; a few are overridden
  # to build the hard cases: a high-similarity low-confidence distractor
  # (similarity-only fails) and a low-confidence target beside a confident
  # token-sharing distractor (confidence-only fails).

  @type candidate :: %{uri: String.t(), value: String.t(), confidence: float(), id: integer()}

  @doc "The twenty memories: `{uri, value, confidence}`."
  @spec memories() :: [{String.t(), String.t(), float()}]
  def memories do
    [
      {"viking://user/memories/preferences/language", "prefers Elixir over Go", 0.9},
      {"viking://user/memories/preferences/theme", "uses dark theme everywhere", 0.7},
      {"viking://user/memories/preferences/editor", "edits with Neovim and tmux", 0.65},
      {"viking://user/memories/preferences/shell", "prefers Zsh over Bash", 0.8},
      {"viking://user/memories/preferences/timezone", "works in Europe/Berlin time", 0.5},
      {"viking://user/memories/profile/name", "user name is Ada", 0.95},
      {"viking://user/memories/profile/role", "is a backend engineer", 0.85},
      {"viking://user/memories/profile/location", "based in Berlin", 0.75},
      {"viking://user/memories/entities/repos/agent_db", "maintains the agent_db repo", 0.8},
      {"viking://user/memories/entities/people/grace", "works with Grace on search", 0.6},
      {"viking://user/memories/entities/tooling/ci", "CI runs on GitHub Actions", 0.55},
      {"viking://user/memories/events/released-1-2", "shipped version 1.2 in March", 0.7},
      {"viking://user/memories/events/elixirconf", "attended ElixirConf in September", 0.5},
      {"viking://user/memories/events/incident", "postgres outage on Friday", 0.65},
      {"viking://user/memories/experiences/nifs", "learned NIFs crash the BEAM when misused",
       0.6},
      {"viking://user/memories/experiences/ecto", "prefers Ecto changesets for validation", 0.75},
      {"viking://user/memories/experiences/liveview", "uses LiveView for dashboards", 0.7},
      {"viking://user/memories/preferences/notifications", "mutes notifications after 6pm", 0.4},
      {"viking://user/memories/entities/repos/handbook", "docs live in the handbook repo", 0.45},
      {"viking://user/memories/events/demo", "tried Go once for a demo", 0.35}
    ]
  end

  @doc "The twenty queries: `{query, expected_uri}`."
  @spec queries() :: [{String.t(), String.t()}]
  def queries do
    [
      {"likes Elixir", "viking://user/memories/preferences/language"},
      {"dark mode", "viking://user/memories/preferences/theme"},
      {"Neovim setup", "viking://user/memories/preferences/editor"},
      {"Zsh or Bash", "viking://user/memories/preferences/shell"},
      {"Berlin working hours", "viking://user/memories/preferences/timezone"},
      {"who is the user", "viking://user/memories/profile/name"},
      {"backend developer", "viking://user/memories/profile/role"},
      {"lives in Berlin", "viking://user/memories/profile/location"},
      {"agent_db maintainer", "viking://user/memories/entities/repos/agent_db"},
      {"Grace search work", "viking://user/memories/entities/people/grace"},
      {"CI workflows", "viking://user/memories/entities/tooling/ci"},
      {"March release", "viking://user/memories/events/released-1-2"},
      {"September conference", "viking://user/memories/events/elixirconf"},
      {"Friday database outage", "viking://user/memories/events/incident"},
      {"BEAM crash course", "viking://user/memories/experiences/nifs"},
      {"changeset validation", "viking://user/memories/experiences/ecto"},
      {"uses dashboards", "viking://user/memories/experiences/liveview"},
      {"mutes after 6pm", "viking://user/memories/preferences/notifications"},
      {"handbook documentation", "viking://user/memories/entities/repos/handbook"},
      {"Go demo", "viking://user/memories/events/demo"}
    ]
  end

  @doc "Controlled vectors per text. Queries sit 5 degrees from their target."
  @spec vectors() :: %{String.t() => [float()]}
  def vectors do
    base =
      Map.new(memories(), fn {_uri, value, _conf} -> {value, spread_vector(value)} end)

    with_overrides = Map.merge(base, overrides())

    queries_vec =
      Map.new(queries(), fn {query, expected_uri} ->
        target_value =
          memories()
          |> Enum.find(fn {uri, _v, _c} -> uri == expected_uri end)
          |> elem(1)

        {query, rotate(Map.fetch!(with_overrides, target_value), 5.0)}
      end)

    Map.merge(with_overrides, queries_vec)
  end

  @doc "Encodes a float list as float32 bytes (the inference port shape)."
  @spec encode([float()]) :: binary()
  def encode(vec) when is_list(vec) do
    for x <- vec, into: <<>>, do: <<x::float-32>>
  end

  @doc "Cosine similarity of two float lists (-1..1, 0 when degenerate)."
  @spec cosine([float()], [float()]) :: float()
  def cosine(a, b) when length(a) == length(b) and length(a) > 0 do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    na = :math.sqrt(Enum.map(a, &(&1 * &1)) |> Enum.sum())
    nb = :math.sqrt(Enum.map(b, &(&1 * &1)) |> Enum.sum())

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
  end

  def cosine(_a, _b), do: 0.0

  @doc "Candidates as maps with stable ids."
  @spec candidates() :: [candidate()]
  def candidates do
    memories()
    |> Enum.with_index(1)
    |> Enum.map(fn {{uri, value, conf}, id} ->
      %{id: id, uri: uri, value: value, confidence: conf}
    end)
  end

  @doc "Confidence-only order (today's recall without a term)."
  @spec rank_confidence([candidate()]) :: [candidate()]
  def rank_confidence(rows) do
    Enum.sort_by(rows, &{-&1.confidence, &1.uri, &1.id})
  end

  @doc "Similarity-only order for a query vector."
  @spec rank_similarity([candidate()], [float()], %{String.t() => [float()]}) :: [candidate()]
  def rank_similarity(rows, query_vec, vecs) do
    rows
    |> Enum.map(fn row -> {cosine(query_vec, Map.fetch!(vecs, row.value)), row} end)
    |> Enum.sort_by(fn {sim, row} -> {-sim, -row.confidence, row.uri, row.id} end)
    |> Enum.map(&elem(&1, 1))
  end

  @w_conf 0.5
  @w_sim 0.5
  @exact_boost 0.15
  @w_decay 0.1
  @stale_after_ms 30 * 24 * 60 * 60 * 1_000

  @doc "Blend weights, mirroring the production recall formula."
  @spec weights() :: {float(), float(), float(), float()}
  def weights, do: {@w_conf, @w_sim, @exact_boost, @w_decay}

  @doc "Deterministic blend of confidence and normalized similarity."
  @spec blend_score(float(), float(), boolean()) :: float()
  def blend_score(confidence, sim01, exact?), do: blend_score(confidence, sim01, exact?, 0.0)

  @doc "Blend with a staleness penalty, mirroring production decay."
  @spec blend_score(float(), float(), boolean(), float()) :: float()
  def blend_score(confidence, sim01, exact?, staleness01) do
    @w_conf * confidence + @w_sim * sim01 + if(exact?, do: @exact_boost, else: 0.0) -
      @w_decay * staleness01
  end

  @doc "Staleness of a surfaced time, mirroring production decay."
  @spec staleness(integer() | nil, integer()) :: float()
  def staleness(nil, _now_ms), do: 1.0

  def staleness(last_surfaced_at, now_ms) do
    min(1.0, max(0.0, (now_ms - last_surfaced_at) / @stale_after_ms))
  end

  @doc "Blended order: confidence + cosine + exact boost over controlled vectors."
  @spec rank_blended([candidate()], String.t(), [float()], %{String.t() => [float()]}) ::
          [candidate()]
  def rank_blended(rows, term, query_vec, vecs) do
    rank_blended_decay(rows, term, query_vec, vecs, System.system_time(:millisecond))
  end

  @doc "Blended order with decay: stale rows rank below fresh equals."
  @spec rank_blended_decay([candidate()], String.t(), [float()], %{String.t() => [float()]}, integer()) ::
          [candidate()]
  def rank_blended_decay(rows, term, query_vec, vecs, now_ms) do
    needle = String.downcase(term)

    rows
    |> Enum.map(fn row ->
      sim = cosine(query_vec, Map.fetch!(vecs, row.value))
      sim01 = (sim + 1.0) / 2.0
      exact? = String.contains?(String.downcase(row.value), needle)
      {blend_score(row.confidence, sim01, exact?, staleness(Map.get(row, :last_surfaced_at), now_ms)),
       row}
    end)
    |> Enum.sort_by(fn {score, row} -> {-score, -row.confidence, row.uri, row.id} end)
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Fraction of queries whose expected URI is in the top-k."
  @spec recall_at_k([{String.t(), String.t()}], ([candidate()] -> [candidate()]), pos_integer()) ::
          float()
  def recall_at_k(queries, rank_fn, k) do
    hits =
      Enum.count(queries, fn {_query, expected_uri} ->
        ranked = rank_fn.(candidates())
        ranked |> Enum.take(k) |> Enum.any?(&(&1.uri == expected_uri))
      end)

    hits / length(queries)
  end

  @doc "Reports recall@1/@3 for all three modes. Query-aware modes rank per query."
  @spec report() :: %{confidence: map(), similarity: map(), blended: map()}
  def report do
    vecs = vectors()
    cands = candidates()
    qs = queries()

    %{
      confidence: %{at_1: recall_at_k(qs, fn _ -> rank_confidence(cands) end, 1)},
      similarity: %{
        at_1: hit_rate(qs, cands, vecs, &rank_similarity/3, 1),
        at_3: hit_rate(qs, cands, vecs, &rank_similarity/3, 3)
      },
      blended: %{
        at_1: hit_rate_blended(qs, cands, vecs, 1),
        at_3: hit_rate_blended(qs, cands, vecs, 3)
      }
    }
  end

  defp hit_rate(qs, cands, vecs, rank_fn, k) do
    hits =
      Enum.count(qs, fn {query, expected_uri} ->
        qv = Map.fetch!(vecs, query)
        scoped = scope_candidates(cands, query)
        ranked = rank_fn.(scoped, qv, vecs)
        ranked |> Enum.take(k) |> Enum.any?(&(&1.uri == expected_uri))
      end)

    hits / length(qs)
  end

  defp hit_rate_blended(qs, cands, vecs, k) do
    hits =
      Enum.count(qs, fn {query, expected_uri} ->
        qv = Map.fetch!(vecs, query)
        scoped = scope_candidates(cands, query)
        ranked = rank_blended(scoped, query, qv, vecs)
        ranked |> Enum.take(k) |> Enum.any?(&(&1.uri == expected_uri))
      end)

    hits / length(qs)
  end

  # The production candidate gate: strict substring matches, else token-overlap
  # across the scope. Mirrors the recall implementation so the numbers transfer.
  defp scope_candidates(cands, query) do
    needle = String.downcase(query)
    strict = Enum.filter(cands, &String.contains?(String.downcase(&1.value), needle))

    if strict != [] do
      strict
    else
      qtokens = MapSet.new(tokens(query))

      Enum.filter(cands, fn row ->
        not MapSet.disjoint?(MapSet.new(tokens(row.value)), qtokens)
      end)
    end
  end

  defp tokens(text) do
    text |> String.downcase() |> then(&Regex.scan(~r/[a-z0-9]+/, &1)) |> List.flatten()
  end

  # Spread texts around the unit circle by hash so unrelated texts are far apart.
  defp spread_vector(text) do
    angle = :erlang.phash2(text, 360) * :math.pi() / 180.0
    [:math.cos(angle), :math.sin(angle), 0.1 * :math.cos(2 * angle), 0.1 * :math.sin(3 * angle)]
  end

  # A query starts 5 degrees from its target: near, but not identical.
  defp rotate([a, b, c, d], degrees) do
    angle = degrees * :math.pi() / 180.0

    [
      a * :math.cos(angle) - b * :math.sin(angle),
      a * :math.sin(angle) + b * :math.cos(angle),
      c,
      d
    ]
  end

  # Hard cases:
  # - The handbook vector sits 2 degrees from the Berlin location memory, so
  #   the "lives in Berlin" query (5 degrees out) is nearer the low-confidence
  #   handbook distractor than its target: similarity-only fails, the blend
  #   (confidence 0.75 vs 0.45) recovers it.
  defp overrides do
    location_value = "based in Berlin"
    handbook_value = "docs live in the handbook repo"

    %{
      handbook_value => rotate(spread_vector(location_value), 2.0)
    }
  end
end
