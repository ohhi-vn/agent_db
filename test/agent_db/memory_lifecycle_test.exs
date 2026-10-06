defmodule AgentDb.MemoryLifecycleTest do
  @moduledoc false
  # Foundations of a memory lifecycle: surfaced tracking, the candidate gate,
  # conflict surfacing, and decay-aware ranking. Each slice is additive and
  # verified against the default SQLite provider; provider parity for the new
  # storage operations lives in the storage contract.
  use ExUnit.Case, async: false

  alias AgentDb.Cache
  alias AgentDb.Store.SQLite

  @lang "viking://user/memories/preferences/language"
  @name "viking://user/memories/profile/name"
  @theme "viking://user/memories/preferences/theme"

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  # -- slice 1: surfaced tracking + importance --

  test "importance round-trips and defaults when omitted" do
    assert {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9, importance: 0.8)
    assert {:ok, _} = AgentDb.remember(@name, "ada")

    assert {:ok, [held]} = AgentDb.recall(@lang)
    assert held.importance == 0.8

    assert {:ok, [defaulted]} = AgentDb.recall(@name)
    assert defaulted.importance == AgentDb.Application.Memories.default_importance()
  end

  test "invalid importance is rejected and nothing is recorded" do
    assert {:error, {:invalid_importance, 1.5}} =
             AgentDb.remember(@lang, "too much", importance: 1.5)

    assert {:ok, []} = AgentDb.recall(@lang)
  end

  test "a recalled memory reports surfaced while an unrecalled one stays NULL" do
    assert {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")
    assert {:ok, _} = AgentDb.remember(@theme, "dark mode")

    assert {:ok, [_]} = AgentDb.recall(@lang)

    assert {:ok, [surfaced]} = AgentDb.recall(@lang)
    assert is_integer(surfaced.last_surfaced_at)

    assert {:ok, [row]} =
             AgentDb.Runtime.storage().recall_memories(@theme, nil, [:active])

    assert is_nil(row.last_surfaced_at)
  end

  test "a legacy memory_meta gains the tracking columns without losing rows" do
    path = AgentDb.Test.Scratch.dir("memory-lifecycle") <> ".db"
    {:ok, conn} = SQLite.open(path)
    on_exit(fn -> File.rm_rf(path) end)

    # A database as it looked before tracking: no new columns and a CHECK
    # that never heard of candidates.
    :ok =
      SQLite.exec(conn, """
      CREATE TABLE nodes (
        uri TEXT PRIMARY KEY, parent_uri TEXT, name TEXT NOT NULL,
        kind TEXT NOT NULL, content TEXT, abstract TEXT, overview TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
      """)

    :ok =
      SQLite.exec(conn, """
      CREATE TABLE memory_meta (
        id INTEGER PRIMARY KEY AUTOINCREMENT, uri TEXT NOT NULL,
        value TEXT NOT NULL, confidence REAL NOT NULL, source TEXT,
        status TEXT NOT NULL CHECK (status IN ('active', 'superseded')),
        supersedes INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
      """)

    :ok =
      SQLite.exec_write(
        conn,
        "INSERT INTO nodes (uri, parent_uri, name, kind, created_at, updated_at) VALUES ('viking://user/memories/profile/name', 'viking://user/memories/profile', 'name', 'doc', 1, 1)",
        []
      )

    :ok =
      SQLite.exec_write(
        conn,
        "INSERT INTO memory_meta (uri, value, confidence, status, created_at, updated_at) VALUES ('viking://user/memories/profile/name', 'ada', 0.9, 'active', 1, 1)",
        []
      )

    assert :ok = SQLite.ensure_schema(conn)
    assert :ok = SQLite.ensure_schema(conn)

    {:ok, cols} = SQLite.query(conn, "PRAGMA table_info(memory_meta)", [])
    names = Enum.map(cols, fn [_cid, name | _] -> name end)
    assert "importance" in names
    assert "last_surfaced_at" in names

    # The row survived the rebuild, and candidates are now accepted.
    assert {:ok, [["ada"]]} = SQLite.query(conn, "SELECT value FROM memory_meta", [])

    assert :ok =
             SQLite.exec_write(
               conn,
               "INSERT INTO memory_meta (uri, value, confidence, status, created_at, updated_at) VALUES ('viking://user/memories/profile/name', 'ada-2', 0.5, 'candidate', 1, 1)",
               []
             )

    :ok = SQLite.close(conn)
  end

  # -- slice 2: candidate gate --

  test "an opt-in candidate waits outside recall until promoted" do
    assert {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", candidate: true)

    assert {:ok, []} = AgentDb.recall(@lang)

    assert {:ok, [waiting]} = AgentDb.pending_memory_candidates(uri: @lang)
    assert waiting.value == "prefers Elixir"
    assert waiting.status == :candidate

    assert {:ok, _} = AgentDb.promote_memory(@lang)

    assert {:ok, [active]} = AgentDb.recall(@lang)
    assert active.value == "prefers Elixir"
    assert active.status == :active

    assert {:error, :no_candidate} = AgentDb.promote_memory(@lang)
  end

  test "a rejected candidate leaves no trace" do
    assert {:ok, _} = AgentDb.remember(@theme, "dark mode", candidate: true)
    assert :ok = AgentDb.reject_memory_candidate(@theme)

    assert {:ok, []} = AgentDb.recall(uri: @theme, include_superseded: true)
    assert {:error, :not_found} = AgentDb.read(@theme)
    assert {:error, :no_candidate} = AgentDb.reject_memory_candidate(@theme)
  end

  test "rejecting beside an active belief keeps the belief and repairs the document" do
    assert {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9)
    assert {:ok, _} = AgentDb.remember(@lang, "prefers Go", confidence: 0.9, candidate: true)
    assert :ok = AgentDb.reject_memory_candidate(@lang)

    assert {:ok, [active]} = AgentDb.recall(@lang)
    assert active.value == "prefers Elixir"
    assert {:ok, "prefers Elixir"} = AgentDb.read(@lang)
  end

  test "the gate holds duplicates and near-zero beliefs as candidates" do
    assert {:ok, _} = AgentDb.remember(@name, "ada lovelace", confidence: 0.9)

    assert {:ok, _} =
             AgentDb.remember("viking://user/memories/profile/alias", "ada lovelace", confidence: 0.9)

    assert {:ok, []} = AgentDb.recall("viking://user/memories/profile/alias")

    assert {:ok, _} =
             AgentDb.remember("viking://user/memories/events/whisper", "barely held", confidence: 0.05)

    assert {:ok, []} = AgentDb.recall("viking://user/memories/events/whisper")

    assert {:ok, _} =
             AgentDb.remember("viking://user/memories/events/loud", "firmly held", confidence: 0.9)

    assert {:ok, [_]} = AgentDb.recall("viking://user/memories/events/loud")
  end

  # -- provider parity: the same lifecycle through the fake provider --

  defmodule FakeProviderTest do
    use ExUnit.Case, async: false

    alias AgentDb.Test.Fakes.Storage

    setup do
      Application.put_env(:agent_db, :storage_adapter, Storage)
      Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
      Storage.reset()
      :ok = Application.stop(:agent_db)
      {:ok, _} = Application.ensure_all_started(:agent_db)

      on_exit(fn ->
        Application.delete_env(:agent_db, :storage_adapter)
        Application.delete_env(:agent_db, :data_dir)
        AgentDb.Test.Script.clear(:fake_storage)
      end)

      :ok
    end

    test "candidates wait outside default recall until promoted" do
      uri = "viking://user/memories/preferences/language"

      assert :ok = Storage.put_memory(uri, "prefers Elixir", 0.9, nil, status: :candidate)
      assert {:ok, []} = Storage.recall_memories(uri, nil, [:active])
      assert {:ok, [_]} = Storage.recall_memories(uri, nil, [:candidate])

      assert {:ok, :promoted} = Storage.promote_memory(uri)
      assert {:ok, [active]} = Storage.recall_memories(uri, nil, [:active])
      assert active.value == "prefers Elixir"

      assert {:error, :no_candidate} = Storage.promote_memory(uri)
    end

    test "reject repairs the document beside an active belief" do
      uri = "viking://user/memories/preferences/language"

      assert :ok = Storage.put_memory(uri, "prefers Elixir", 0.9, nil)
      assert :ok = Storage.put_memory(uri, "prefers Go", 0.9, nil, status: :candidate)
      assert :ok = Storage.reject_memory_candidate(uri)

      assert {:ok, [active]} = Storage.recall_memories(uri, nil, [:active])
      assert active.value == "prefers Elixir"
      assert {:ok, node} = Storage.get_node(uri)
      assert node.content == "prefers Elixir"
    end

    test "surfacing is recorded and conflicts use stored vectors" do
      a = "viking://user/memories/preferences/first"
      b = "viking://user/memories/preferences/second"
      c = "viking://user/memories/preferences/third"
      d = "viking://user/memories/events/other"

      assert :ok = Storage.put_memory(a, "likes Elixir a lot", 0.9, nil, importance: 0.7)
      assert :ok = Storage.put_memory(b, "likes Elixir a lot", 0.9, nil)
      assert :ok = Storage.put_memory(c, "mutes notifications at night", 0.9, nil)
      assert :ok = Storage.put_memory(d, "likes Elixir a lot", 0.9, nil)

      assert {:ok, [row]} = Storage.recall_memories(a, nil, [:active])
      assert row.importance == 0.7
      assert row.last_surfaced_at == nil

      assert :ok = Storage.mark_memories_surfaced([row.id])

      assert {:ok, [touched]} = Storage.recall_memories(a, nil, [:active])
      assert is_integer(touched.last_surfaced_at)

      enc = fn vec -> for x <- vec, into: <<>>, do: <<x::float-32>> end

      for {uri, vec} <- [
            {a, [1.0, 0.0, 0.0, 0.0]},
            {b, [0.99, 0.01, 0.0, 0.0]},
            {c, [0.0, 0.0, 0.0, 1.0]},
            {d, [0.99, 0.01, 0.0, 0.0]}
          ] do
        {:ok, job_id} = Storage.enqueue_job(:embed, %{uri: uri, content: ""})
        {:ok, _} = Storage.dequeue_job([:embed])
        assert {:ok, :stored} = Storage.put_embedding_result(job_id, uri, enc.(vec))
      end

      # Only the same-type near-duplicate pairs: not the distinct value,
      # not the other-type lookalike.
      assert {:ok, [%{uri_a: first, uri_b: second, similarity: sim}]} =
               Storage.memory_conflict_pairs("viking://user/memories")

      assert Enum.sort([first, second]) == Enum.sort([a, b])
      assert sim > 0.9
    end

    test "conflicts are unevaluable without stored vectors, not empty" do
      uri = "viking://user/memories/preferences/first"
      assert :ok = Storage.put_memory(uri, "likes Elixir a lot", 0.9, nil)

      assert {:error, :embeddings_unavailable} =
               Storage.memory_conflict_pairs("viking://user/memories/preferences")
    end
  end

  # -- slice 4: decay penalty + promotion-as-suggest --

  test "a stale memory ranks below an otherwise equal fresh one" do
    alias AgentDb.Test.Support.MemoryRankingFixture, as: Fixture

    now = System.system_time(:millisecond)
    vecs = Fixture.vectors()
    value = "prefers Elixir over Go"
    query_vec = Map.fetch!(vecs, "likes Elixir")

    fresh = %{id: 1, uri: "viking://user/memories/preferences/fresh", value: value, confidence: 0.9, last_surfaced_at: now}
    stale = %{id: 2, uri: "viking://user/memories/preferences/stale", value: value, confidence: 0.9, last_surfaced_at: nil}

    assert [first, second] = Fixture.rank_blended_decay([stale, fresh], "likes Elixir", query_vec, vecs, now)
    assert first.uri == fresh.uri
    assert second.uri == stale.uri

    # The production formula agrees on the penalty across the grid.
    for conf <- [0.0, 0.5, 0.9],
        sim <- [0.0, 0.5, 1.0],
        exact? <- [true, false],
        stale01 <- [0.0, 0.5, 1.0] do
      assert Fixture.blend_score(conf, sim, exact?, stale01) ==
               AgentDb.Application.Memories.blend_score(conf, sim, exact?, stale01)
    end

    assert Fixture.weights() == AgentDb.Application.Memories.blend_weights()
  end

  test "a gated duplicate is suggested through pending and promotes into an ordinary memory" do
    held = "viking://user/memories/profile/name"
    repeat = "viking://user/memories/profile/alias"

    assert {:ok, _} = AgentDb.remember(held, "ada lovelace", confidence: 0.9)
    assert {:ok, _} = AgentDb.remember(repeat, "ada lovelace", confidence: 0.9)

    # The repetition surfaces as a pending suggestion, not an auto-merge.
    assert {:ok, [suggested]} = AgentDb.pending_memory_candidates()
    assert suggested.uri == repeat

    assert {:ok, _} = AgentDb.promote_memory(repeat)

    # The promoted memory is ordinary: recalled, readable, documented.
    assert {:ok, [active]} = AgentDb.recall(repeat)
    assert active.value == "ada lovelace"
    assert active.status == :active
    assert {:ok, "ada lovelace"} = AgentDb.read(repeat)
    assert {:ok, []} = AgentDb.pending_memory_candidates()
  end

  # -- slice 3: conflict surfacing --

  test "conflicts surface outside recall and leave recall untouched" do
    assert {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9)

    assert {:ok, before} = AgentDb.recall()

    # No vector extension on this host: unevaluable, never an empty verdict.
    assert {:error, :embeddings_unavailable} = AgentDb.memory_conflicts()

    assert {:ok, again} = AgentDb.recall()

    # Every recall touches surfaced times, so that one clock is set aside;
    # everything else the caller sees is identical.
    assert Enum.map(before, &Map.delete(&1, :last_surfaced_at)) ==
             Enum.map(again, &Map.delete(&1, :last_surfaced_at))
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
