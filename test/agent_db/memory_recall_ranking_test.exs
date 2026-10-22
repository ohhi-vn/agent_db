defmodule AgentDb.MemoryRecallRankingTest do
  use ExUnit.Case, async: false

  alias AgentDb.Application.Memories
  alias AgentDb.Cache
  alias AgentDb.StorageContract.Helpers
  alias AgentDb.Test.Fakes
  alias AgentDb.Test.Support.MemoryRankingFixture, as: Fixture

  defmodule FixtureEmbedder do
    @moduledoc false
    # Deterministic vectors for the integration scenario. Unknown texts get a
    # fixed orthogonal vector so similarities stay deterministic. Call counts
    # land in a public ETS table so a test can prove the read path ran exactly
    # one embed.

    @behaviour AgentDb.Core.Inference
    @call_table :fixture_embedder_calls

    @vectors %{
      "likes Elixir" => [1.0, 0.0, 0.0, 0.0],
      "prefers Elixir over Go" => [0.99, 0.01, 0.0, 0.0],
      "Elixir notes" => [0.0, 1.0, 0.0, 0.0]
    }

    @impl true
    def child_specs(_opts), do: []

    @impl true
    def embed(texts) when is_list(texts) do
      count()

      {:ok,
       Enum.map(texts, fn text ->
         Fixture.encode(Map.get(@vectors, text, [0.0, 0.0, 0.0, 1.0]))
       end)}
    end

    @impl true
    def summarize(_prompt, _opts), do: {:ok, "summary"}

    @impl true
    def model_status do
      %{
        embedding: %{loaded: true, state: :ready, model: "fixture", dim: 4},
        llm: %{loaded: true, state: :ready, model: "fixture", params: "0B"}
      }
    end

    @doc "Empties the call counter; the table survives across tests."
    def reset_calls do
      ensure_table()
      :ets.insert(@call_table, {:count, 0})
      :ok
    end

    @doc "How many times embed/1 has been called since the last reset."
    def embed_calls do
      ensure_table()

      case :ets.lookup(@call_table, :count) do
        [{:count, n}] -> n
        _ -> 0
      end
    end

    defp ensure_table do
      case :ets.whereis(@call_table) do
        :undefined ->
          :ets.new(@call_table, [:named_table, :public])
          :ets.insert(@call_table, {:count, 0})

        _ ->
          :ok
      end
    end

    defp count do
      ensure_table()
      :ets.update_counter(@call_table, :count, 1, {:count, 0})
    end
  end

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Application.put_env(:agent_db, :inference_provider, FixtureEmbedder)
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :inference_provider)
      # The fake-storage tests point the port at the in-memory provider: each
      # file that follows must find the default adapter, not that one.
      Application.delete_env(:agent_db, :storage_adapter)
      AgentDb.Test.Script.clear(:fake_storage)
      AgentDb.Test.Script.clear(:fake_inference)
    end)

    :ok
  end

  # -- eval fixture baseline (tasks 1.1, 1.2) --

  test "fixture reports recall@k for all three modes with blended ahead" do
    report = Fixture.report()

    assert report.confidence == %{at_1: 0.05}
    assert report.similarity == %{at_1: 0.95, at_3: 1.0}
    assert report.blended == %{at_1: 1.0, at_3: 1.0}
  end

  test "fixture blend matches the production blend formula" do
    assert Fixture.weights() == Memories.blend_weights()

    for conf <- [0.0, 0.35, 0.5, 0.9, 1.0],
        sim <- [0.0, 0.25, 0.5, 0.99, 1.0],
        exact? <- [true, false] do
      assert Fixture.blend_score(conf, sim, exact?) == Memories.blend_score(conf, sim, exact?)
    end

    for conf <- [0.0, 0.5, 0.9],
        sim <- [0.0, 1.0],
        staleness <- [0.0, 1.0],
        importance <- [0.0, 0.25, 1.0] do
      assert Fixture.blend_score(conf, sim, true, staleness, importance) ==
               Memories.blend_score(conf, sim, true, staleness, importance)
    end
  end

  test "production cosine agrees with the fixture on controlled vectors" do
    vecs = Fixture.vectors()

    for {query, _expected} <- Fixture.queries() do
      for {_uri, value, _conf} <- Fixture.memories() do
        expected = Fixture.cosine(Map.fetch!(vecs, query), Map.fetch!(vecs, value))

        actual =
          Memories.cosine(
            Fixture.encode(Map.fetch!(vecs, query)),
            Fixture.encode(Map.fetch!(vecs, value))
          )

        assert_in_delta actual, expected, 1.0e-6
      end
    end
  end

  # -- blended recall wiring (tasks 2.4, 2.5) --

  # Term recall ranks from STORED vectors through the fake storage provider:
  # this host has no SQLite vector extension, so routing these through the
  # real adapter could only ever exercise the fallback. The fake holds
  # embeddings in memory, which is what makes the blend observable here.
  defp with_fake_storage do
    Application.put_env(:agent_db, :storage_adapter, Fakes.Storage)
    AgentDb.Test.Script.clear(:fake_storage)
    Helpers.stop_workers()
    :ok
  end

  defp seed_vectors(vectors_by_uri) do
    Helpers.store_vectors(Fakes.Storage, vectors_by_uri)
  end

  test "a paraphrased term finds the firmly-held fact first" do
    with_fake_storage()

    lang = "viking://user/memories/preferences/language"
    notes = "viking://user/memories/preferences/notes"

    assert :ok = Fakes.Storage.put_memory(lang, "prefers Elixir over Go", 0.9, nil)
    assert :ok = Fakes.Storage.put_memory(notes, "Elixir notes", 0.95, nil)

    # Stored vectors: lan close to the query's phrasing, notes far from it.
    seed_vectors(%{
      lang => [1.0, 0.0, 0.0, 0.0],
      notes => [0.0, 0.0, 1.0, 0.0]
    })

    # No value contains "likes Elixir", so the strict gate is empty and the
    # token gate ("elixir") admits both: the blend must outrank the more
    # confident but irrelevant note.
    assert {:ok, [first, second]} = AgentDb.recall(term: "likes Elixir")
    assert first.uri == lang
    assert first.value == "prefers Elixir over Go"
    assert second.uri == notes
    # The blend was ranked from the stored vectors, and the recall says so.
    assert first.semantic_ranked
    assert second.semantic_ranked
  end

  # -- fallback (task 2.4) --

  test "an inference failure falls back to confidence order" do
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)
    Fakes.Inference.stub_embed({:error, :model_loading})

    lang = "viking://user/memories/preferences/language"
    name = "viking://user/memories/profile/name"

    assert {:ok, _} = AgentDb.remember(lang, "prefers Elixir", confidence: 0.2)
    assert {:ok, _} = AgentDb.remember(name, "prefers Elixir too", confidence: 0.9)

    # Both contain "elixir": strict gate hits, embed fails, confidence wins.
    assert {:ok, [first, second]} = AgentDb.recall(term: "elixir")
    assert first.uri == name
    assert second.uri == lang
    assert [first.semantic_ranked, second.semantic_ranked] == [false, false]
  end

  test "a provider that is not ready never gets an embed call" do
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)

    AgentDb.Test.Script.put(:fake_inference, :model_status, %{
      embedding: %{loaded: false, state: :loading, model: "fake", dim: 4},
      llm: %{loaded: false, state: :loading, model: "fake", params: "0B"}
    })

    lang = "viking://user/memories/preferences/language"
    notes = "viking://user/memories/preferences/notes"

    assert {:ok, _} = AgentDb.remember(lang, "prefers Elixir over Go", confidence: 0.9)
    assert {:ok, _} = AgentDb.remember(notes, "Elixir notes", confidence: 0.95)

    assert {:ok, [first, second]} = AgentDb.recall(term: "likes Elixir")
    # Confidence order, and the recall says the blend was not applied.
    assert first.uri == notes
    assert second.uri == lang
    assert [first.semantic_ranked, second.semantic_ranked] == [false, false]
  end

  # -- preserved semantics (task 2.3) --

  test "recall without a term keeps confidence order" do
    lang = "viking://user/memories/preferences/language"
    name = "viking://user/memories/profile/name"

    assert {:ok, _} = AgentDb.remember(lang, "low", confidence: 0.2)
    assert {:ok, _} = AgentDb.remember(name, "high", confidence: 0.9)

    assert {:ok, found} = AgentDb.recall()
    assert Enum.map(found, & &1.confidence) == [0.9, 0.2]
  end

  test "equal-confidence rows are ranked by importance" do
    with_fake_storage()
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)

    lang = "viking://user/memories/preferences/language"
    notes = "viking://user/memories/preferences/notes"

    assert :ok = Fakes.Storage.put_memory(lang, "wants Elixir", 0.5, nil, importance: 0.9)
    assert :ok = Fakes.Storage.put_memory(notes, "wants Elixir too", 0.5, nil, importance: 0.1)

    # Identical stored vectors: similarity, exactness, and staleness hold the
    # two equal, so the blend's importance term is what separates them.
    seed_vectors(%{
      lang => [1.0, 0.0, 0.0, 0.0],
      notes => [1.0, 0.0, 0.0, 0.0]
    })

    vec = Fixture.encode([1.0, 0.0, 0.0, 0.0])
    Fakes.Inference.stub_embed({:ok, [vec]})

    assert {:ok, [first, second]} = AgentDb.recall(term: "elixir")
    assert first.uri == lang
    assert second.uri == notes
    assert [first.semantic_ranked, second.semantic_ranked] == [true, true]
  end

  test "a term recall embeds the query once and the candidates never" do
    with_fake_storage()

    FixtureEmbedder.reset_calls()

    lang = "viking://user/memories/preferences/language"
    notes = "viking://user/memories/preferences/notes"

    assert :ok = Fakes.Storage.put_memory(lang, "prefers Elixir over Go", 0.9, nil)
    assert :ok = Fakes.Storage.put_memory(notes, "Elixir notes", 0.95, nil)

    seed_vectors(%{
      lang => [0.99, 0.01, 0.0, 0.0],
      notes => [0.0, 1.0, 0.0, 0.0]
    })

    assert {:ok, [first, _second]} = AgentDb.recall(term: "likes Elixir")
    assert first.uri == lang

    # One inference call for the query; reranking the candidates cost no model
    # time at all, because their vectors were already stored.
    assert FixtureEmbedder.embed_calls() == 1
  end

  test "vectors absent for the candidates fall back to confidence order" do
    with_fake_storage()
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)

    vec = Fixture.encode([1.0, 0.0, 0.0, 0.0])
    Fakes.Inference.stub_embed({:ok, [vec]})

    lang = "viking://user/memories/preferences/language"
    name = "viking://user/memories/profile/name"

    assert :ok = Fakes.Storage.put_memory(lang, "prefers Elixir", 0.2, nil)
    assert :ok = Fakes.Storage.put_memory(name, "prefers Elixir too", 0.9, nil)

    # No seeded vectors: the stored index cannot answer, so every entry falls
    # back together and the recall says so.
    assert {:ok, [first, second]} = AgentDb.recall(term: "elixir")
    assert first.uri == name
    assert second.uri == lang
    assert [first.semantic_ranked, second.semantic_ranked] == [false, false]
  end

  test "vectors of another dimensionality fall back to confidence order" do
    with_fake_storage()
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)

    lang = "viking://user/memories/preferences/language"
    name = "viking://user/memories/profile/name"

    assert :ok = Fakes.Storage.put_memory(lang, "prefers Elixir", 0.2, nil)
    assert :ok = Fakes.Storage.put_memory(name, "prefers Elixir too", 0.9, nil)

    # Stored vectors are 8-number blobs while the query embeds as 4: the
    # candidates cannot answer the query dimension, so the recall falls back
    # as a whole and reports it.
    seed_vectors(%{
      lang => [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      name => [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    })

    vec = Fixture.encode([1.0, 0.0, 0.0, 0.0])
    Fakes.Inference.stub_embed({:ok, [vec]})

    assert {:ok, [first, second]} = AgentDb.recall(term: "elixir")
    assert first.uri == name
    assert second.uri == lang
    assert [first.semantic_ranked, second.semantic_ranked] == [false, false]
  end

  test "recall still scopes by type and returns empty on no match" do
    lang = "viking://user/memories/preferences/language"

    assert {:ok, _} = AgentDb.remember(lang, "prefers Elixir")

    assert {:ok, [only]} = AgentDb.recall(type: :preferences)
    assert only.uri == lang

    assert {:ok, []} = AgentDb.recall(term: "absolutely-not-present")
    assert {:ok, []} = AgentDb.recall(uri: lang, term: "absolutely-not-present")
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
