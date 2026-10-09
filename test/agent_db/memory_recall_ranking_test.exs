defmodule AgentDb.MemoryRecallRankingTest do
  use ExUnit.Case, async: false

  alias AgentDb.Application.Memories
  alias AgentDb.Cache
  alias AgentDb.Test.Fakes
  alias AgentDb.Test.Support.MemoryRankingFixture, as: Fixture

  defmodule FixtureEmbedder do
    @moduledoc false
    # Deterministic vectors for the integration scenario. Unknown texts get a
    # fixed orthogonal vector so similarities stay deterministic.

    @behaviour AgentDb.Core.Inference

    @vectors %{
      "likes Elixir" => [1.0, 0.0, 0.0, 0.0],
      "prefers Elixir over Go" => [0.99, 0.01, 0.0, 0.0],
      "Elixir notes" => [0.0, 1.0, 0.0, 0.0]
    }

    @impl true
    def child_specs(_opts), do: []

    @impl true
    def embed(texts) when is_list(texts) do
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
  end

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Application.put_env(:agent_db, :inference_provider, FixtureEmbedder)
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :inference_provider)
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

  # -- blended recall wiring (task 2.1) --

  test "a paraphrased term finds the firmly-held fact first" do
    lang = "viking://user/memories/preferences/language"
    notes = "viking://user/memories/preferences/notes"

    assert {:ok, _} = AgentDb.remember(lang, "prefers Elixir over Go", confidence: 0.9)
    assert {:ok, _} = AgentDb.remember(notes, "Elixir notes", confidence: 0.95)

    # No value contains "likes Elixir", so the strict gate is empty and the
    # token gate ("elixir") admits both: the blend must outrank the more
    # confident but irrelevant note.
    assert {:ok, [first, second]} = AgentDb.recall(term: "likes Elixir")
    assert first.uri == lang
    assert first.value == "prefers Elixir over Go"
    assert second.uri == notes
  end

  # -- fallback (task 2.2) --

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
  end

  test "a provider that is not ready never gets an embed call" do
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)

    AgentDb.Test.Script.put(:fake_inference, :model_status, %{
      embedding: %{loaded: false, state: :loading, model: "fake", dim: 4},
      llm: %{loaded: false, state: :loading, model: "fake", params: "0B"}
    })

    # Embed would rank "prefers Elixir over Go" first if called: the recall
    # must stay in confidence order, proving the read path skipped inference.
    Fakes.Inference.stub_embed({
      :ok,
      [
        Fixture.encode([1.0, 0.0, 0.0, 0.0]),
        Fixture.encode([0.99, 0.01, 0.0, 0.0]),
        Fixture.encode([0.0, 1.0, 0.0, 0.0])
      ]
    })

    lang = "viking://user/memories/preferences/language"
    notes = "viking://user/memories/preferences/notes"

    assert {:ok, _} = AgentDb.remember(lang, "prefers Elixir over Go", confidence: 0.9)
    assert {:ok, _} = AgentDb.remember(notes, "Elixir notes", confidence: 0.95)

    assert {:ok, [first, _second]} = AgentDb.recall(term: "likes Elixir")
    assert first.uri == notes
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
