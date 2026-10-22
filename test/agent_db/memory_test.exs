defmodule AgentDb.MemoryTest.BrokenRecallStorage do
  @moduledoc false
  # A storage that answers the strict term read with an empty set but cannot
  # answer any read without a term -- the widening broad read fails with the
  # reader pool's own unavailability reason. Only the recall failure path's
  # callbacks; nothing else.
  def recall_memories(_scope, term, _statuses, _opts) when is_binary(term), do: {:ok, []}

  def recall_memories(_scope, nil, _statuses, _opts), do: {:error, :storage_busy}
  def recall_memories(_scope, nil, _statuses), do: {:error, :storage_busy}
end

defmodule AgentDb.MemoryTest.UnboundedDetailStorage do
  @moduledoc false
  # A storage whose reads fail with an unbounded detail, as a provider's
  # native error shape can. What recall reports is the shared classification,
  # never the detail.
  def recall_memories(_scope, _term, _statuses, _opts), do: {:error, "disk I/O error"}
end

defmodule AgentDb.MemoryTest do
  use ExUnit.Case, async: false

  alias AgentDb.Cache
  alias AgentDb.MemoryTest.BrokenRecallStorage
  alias AgentDb.MemoryTest.UnboundedDetailStorage
  alias AgentDb.ML.ModelManager
  alias AgentDb.Store.{Reader, SQLite}

  @lang "viking://user/memories/preferences/language"
  @name "viking://user/memories/profile/name"

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  # -- typed durable memory --

  test "a recorded memory reports its type and value" do
    assert {:ok, @lang} =
             AgentDb.remember(@lang, "prefers Elixir over Go", type: :preferences)

    assert {:ok, [memory]} = AgentDb.recall(@lang)
    assert memory.type == "preferences"
    assert memory.value == "prefers Elixir over Go"
    assert memory.status == :active
  end

  test "the type is the first path segment beneath the memories root" do
    repo = "viking://user/memories/entities/repos/agent_db"
    assert {:ok, ^repo} = AgentDb.remember(repo, "this repo")

    assert {:ok, [memory]} = AgentDb.recall(repo)
    assert memory.type == "entities"
    assert memory.value == "this repo"
  end

  test "a type outside the taxonomy is rejected and nothing is recorded" do
    assert {:error, {:invalid_memory_type, "gossip"}} =
             AgentDb.remember("viking://user/memories/gossip/someone", "heard something")

    assert {:error, :not_found} = AgentDb.read("viking://user/memories/gossip/someone")
    assert {:ok, []} = AgentDb.recall()
  end

  test "a uri outside the memories root is rejected" do
    assert {:error, {:not_a_memory_uri, uri}} =
             AgentDb.remember("viking://resources/notes/a.md", "not a memory")

    assert uri == "viking://resources/notes/a.md"
    assert {:error, :not_found} = AgentDb.read("viking://resources/notes/a.md")
  end

  test "a memory type segment with nothing after it is rejected" do
    assert {:error, {:not_a_memory_uri, _}} =
             AgentDb.remember("viking://user/memories/preferences", "no name")
  end

  test "an out-of-range confidence is rejected" do
    assert {:error, {:invalid_confidence, 1.5}} = AgentDb.remember(@lang, "x", confidence: 1.5)
  end

  # -- recording and revising --

  test "first record creates the memory" do
    assert {:ok, @lang} = AgentDb.remember(@lang, "prefers Elixir over Go")
    assert {:ok, "prefers Elixir over Go"} = AgentDb.read(@lang)
  end

  test "re-recording revises rather than duplicating" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir over Go")
    {:ok, _} = AgentDb.remember(@lang, "strongly prefers Elixir")

    assert {:ok, "strongly prefers Elixir"} = AgentDb.read(@lang)
    assert {:ok, [memory]} = AgentDb.recall(@lang)
    assert memory.value == "strongly prefers Elixir"
  end

  test "distinct uris coexist without superseding each other" do
    {:ok, _} = AgentDb.remember("viking://user/memories/entities/repos/agent_db", "this repo")
    {:ok, _} = AgentDb.remember("viking://user/memories/events/released-1-2", "shipped 1.2")

    assert {:ok, [a, b]} = AgentDb.recall()

    assert Enum.map([a, b], & &1.uri) == [
             "viking://user/memories/entities/repos/agent_db",
             "viking://user/memories/events/released-1-2"
           ]

    assert Enum.all?([a, b], &(&1.status == :active))
  end

  # -- recall --

  test "recall by type returns only that type" do
    {:ok, _} = AgentDb.remember("viking://user/memories/events/released", "shipped 1.2")
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")

    assert {:ok, [only]} = AgentDb.recall(type: :events)
    assert only.uri == "viking://user/memories/events/released"
  end

  test "recall by type covers a whole type subtree" do
    {:ok, _} = AgentDb.remember("viking://user/memories/entities/repos/agent_db", "this repo")
    {:ok, _} = AgentDb.remember("viking://user/memories/entities/people/ada", "a person")

    assert {:ok, found} = AgentDb.recall(type: :entities)
    assert length(found) == 2
  end

  test "recall by subtree uri" do
    {:ok, _} = AgentDb.remember("viking://user/memories/preferences/language", "elixir")
    {:ok, _} = AgentDb.remember("viking://user/memories/preferences/ui/theme", "dark")
    {:ok, _} = AgentDb.remember(@name, "ada")

    assert {:ok, found} = AgentDb.recall("viking://user/memories/preferences")
    assert length(found) == 2
  end

  test "an exact uri recall returns only that memory" do
    {:ok, _} = AgentDb.remember("viking://user/memories/preferences/language", "elixir")
    {:ok, _} = AgentDb.remember("viking://user/memories/preferences/ui/theme", "dark")

    assert {:ok, [only]} = AgentDb.recall("viking://user/memories/preferences/language")
    assert only.uri == "viking://user/memories/preferences/language"
  end

  test "recall excludes superseded memories" do
    {:ok, _} = AgentDb.remember(@lang, "user uses Go")
    {:ok, _} = AgentDb.remember(@lang, "user moved to Elixir")

    assert {:ok, [memory]} = AgentDb.recall(@lang)
    assert memory.value == "user moved to Elixir"
  end

  test "recall orders by descending confidence" do
    {:ok, _} = AgentDb.remember(@lang, "low", confidence: 0.2)
    {:ok, _} = AgentDb.remember(@name, "high", confidence: 0.9)
    {:ok, _} = AgentDb.remember("viking://user/memories/events/mid", "mid", confidence: 0.5)

    assert {:ok, found} = AgentDb.recall()
    assert Enum.map(found, & &1.confidence) == [0.9, 0.5, 0.2]
  end

  test "recall of a term that matches nothing returns an empty result" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")

    assert {:ok, []} = AgentDb.recall(term: "absolutely-not-present")
    assert {:ok, []} = AgentDb.recall(uri: @lang, term: "absolutely-not-present")
  end

  test "recall by term matches the value case-insensitively" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir over Go")

    assert {:ok, [found]} = AgentDb.recall(term: "elixir")
    assert found.uri == @lang
  end

  test "recall rejects an unrecognised type rather than ignoring it" do
    assert {:error, {:invalid_memory_type, "gossip"}} = AgentDb.recall(type: :gossip)
  end

  test "recall rejects a uri outside the memories root" do
    assert {:error, {:not_a_memory_uri, _}} = AgentDb.recall("viking://resources/notes")
  end

  test "a malformed recall scope is an error, not a crash" do
    assert {:error, :invalid_uri} = AgentDb.recall("notaschi")
    assert {:error, :invalid_uri} = AgentDb.recall(uri: "notaschi")
  end

  test "the whole root recalls with each memory's own type" do
    files = [
      {@name, "profile"},
      {@lang, "preferences"},
      {"viking://user/memories/events/released", "events"},
      {"viking://user/memories/entities/repos/agent_db", "entities"}
    ]

    for {uri, _type} <- files, do: {:ok, _} = AgentDb.remember(uri, "recall types " <> uri)

    assert {:ok, found} = AgentDb.recall()
    by_uri = Map.new(found, &{&1.uri, &1.type})

    for {uri, type} <- files do
      assert Map.fetch!(by_uri, uri) == type
    end

    # Nothing recalled reports an absent type.
    assert Enum.all?(found, &is_binary(&1.type))
  end

  # -- bounding and provenance --

  test "a recall is bounded and reports that the bound was reached" do
    parent = "viking://user/memories/preferences/recall-bound"

    for i <- 1..7, do: {:ok, _} = AgentDb.remember("#{parent}/f#{i}", "fact #{i}")

    assert {:ok, bounded} = AgentDb.recall(uri: parent, top_k: 5)
    assert length(bounded) == 5
    assert Enum.all?(bounded, & &1.truncated)

    # A bound above the answered set does not cut: the flag says so plainly.
    assert {:ok, whole} = AgentDb.recall(uri: parent, top_k: 50)
    assert length(whole) == 7
    assert Enum.all?(whole, &(&1.truncated == false))
  end

  test "an unbounded recall reports the default bound it served" do
    storage = AgentDb.Runtime.storage()
    parent = "viking://user/memories/preferences/recall-default-bound"

    for i <- 1..501 do
      label = String.pad_leading(Integer.to_string(i), 3, "0")

      :ok = storage.put_memory("#{parent}/f#{label}", "fact #{i}", 0.5, nil)
    end

    assert {:ok, rows} = AgentDb.recall(uri: parent)
    assert length(rows) == 500
    assert Enum.all?(rows, & &1.truncated)
  end

  test "a recall is scoped by provenance" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", source: "recall-session-a")
    {:ok, _} = AgentDb.remember(@name, "ada", source: "recall-session-b")

    assert {:ok, [from_a]} = AgentDb.recall(source: "recall-session-a")
    assert from_a.uri == @lang
    assert from_a.source == "recall-session-a"
    assert from_a.truncated == false

    assert {:ok, []} = AgentDb.recall(source: "recall-session-c")
  end

  test "an out-of-range bound is refused rather than substituted" do
    assert {:error, {:invalid_limit, 0}} = AgentDb.recall(top_k: 0)
    assert {:error, {:invalid_limit, 501}} = AgentDb.recall(top_k: 501)
    assert {:error, {:invalid_limit, "ten"}} = AgentDb.recall(top_k: "ten")
  end

  # -- failures are answers, not empty results --

  test "a failed store read is a classified error, never an empty recall" do
    with_broken_recall(fn ->
      # The strict read cannot be answered: the reason is the reader pool's
      # own, bounded.
      assert {:error, :storage_busy} = AgentDb.recall(uri: @lang)

      # The strict term read answered empty, so the widening read ran -- and
      # its failure is reported, not turned into `{:ok, []}`.
      assert {:error, :storage_busy} = AgentDb.recall(uri: @lang, term: "elixir")
    end)
  end

  test "a failure's unbounded detail maps to the shared classification" do
    Application.put_env(:agent_db, :storage_adapter, UnboundedDetailStorage)

    try do
      assert {:error, :error} = AgentDb.recall(uri: @lang)
    after
      Application.delete_env(:agent_db, :storage_adapter)
    end
  end

  # The store is made to refuse reads for exactly one recall, so the failure
  # branch runs against a real `{:error, reason}` from the storage port.
  defp with_broken_recall(fun) do
    Application.put_env(:agent_db, :storage_adapter, BrokenRecallStorage)

    try do
      fun.()
    after
      Application.delete_env(:agent_db, :storage_adapter)
    end
  end

  # -- provenance --

  test "caller-supplied provenance is retained" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9, source: "session-abc")

    assert {:ok, [memory]} = AgentDb.recall(@lang)
    assert memory.confidence == 0.9
    assert memory.source == "session-abc"
  end

  test "confidence defaults when omitted" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")

    assert {:ok, [memory]} = AgentDb.recall(@lang)
    assert memory.confidence == AgentDb.default_confidence()
    assert memory.source == nil
  end

  # -- conflict resolution --

  test "a revised belief supersedes its predecessor" do
    {:ok, _} = AgentDb.remember(@lang, "user uses Go", confidence: 0.6, source: "s-abc")

    {:ok, _} =
      AgentDb.remember(@lang, "user moved the project to Elixir",
        confidence: 0.9,
        source: "s-def"
      )

    assert {:ok, [active]} = AgentDb.recall(@lang)
    assert active.value == "user moved the project to Elixir"

    assert {:ok, history} = AgentDb.recall(uri: @lang, include_superseded: true)
    assert length(history) == 2

    prior = Enum.find(history, &(&1.status == :superseded))
    assert prior.value == "user uses Go"
    assert prior.confidence == 0.6
    assert prior.source == "s-abc"
    # The superseded row names the assertion that replaced it, so the chain is
    # walkable from either end.
    refute is_nil(prior.supersedes)
  end

  test "exactly one assertion is active per uri across repeated revisions" do
    {:ok, _} = AgentDb.remember(@lang, "v1")
    {:ok, _} = AgentDb.remember(@lang, "v2")
    {:ok, _} = AgentDb.remember(@lang, "v3")

    assert {:ok, [only]} = AgentDb.recall(@lang)
    assert only.value == "v3"
    assert only.status == :active

    assert {:ok, history} = AgentDb.recall(uri: @lang, include_superseded: true)
    assert length(history) == 3
    assert Enum.count(history, &(&1.status == :active)) == 1
    assert Enum.count(history, &(&1.status == :superseded)) == 2
  end

  test "superseded history is inspectable and walks to its successor" do
    {:ok, _} = AgentDb.remember(@lang, "user uses Go")
    {:ok, _} = AgentDb.remember(@lang, "user moved to Elixir")

    assert {:ok, history} = AgentDb.recall(uri: @lang, include_superseded: true)

    prior = Enum.find(history, &(&1.status == :superseded))
    assert prior.value == "user uses Go"

    successor = Enum.find(history, &(&1.id == prior.supersedes))
    assert successor.value == "user moved to Elixir"
    assert successor.status == :active
    assert successor.supersedes == nil
  end

  test "removing a memory discards its superseded history" do
    {:ok, _} = AgentDb.remember(@lang, "user uses Go")
    {:ok, _} = AgentDb.remember(@lang, "user moved to Elixir")

    assert :ok = AgentDb.forget(@lang)

    assert {:ok, []} = AgentDb.recall(uri: @lang, include_superseded: true)
    assert {:ok, [0]} = count_memory_meta("viking://user/memories/preferences/language")
  end

  # -- forgetting --

  test "a forgotten memory is no longer recalled or readable" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")
    assert {:ok, _} = AgentDb.read(@lang)

    assert :ok = AgentDb.forget(@lang)

    assert {:ok, []} = AgentDb.recall(type: :preferences)
    assert {:error, :not_found} = AgentDb.read(@lang)
  end

  test "forgetting removes provenance, not just the value" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9, source: "s-abc")
    assert :ok = AgentDb.forget(@lang)

    assert {:ok, []} = AgentDb.recall(uri: @lang, include_superseded: true)
    assert {:ok, [0]} = count_memory_meta(@lang)
  end

  test "forgetting one memory leaves others intact" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9, source: "s-abc")
    {:ok, _} = AgentDb.remember(@name, "ada", confidence: 0.7, source: "s-def")

    assert :ok = AgentDb.forget(@lang)

    assert {:ok, [kept]} = AgentDb.recall(@name)
    assert kept.value == "ada"
    assert kept.confidence == 0.7
    assert kept.source == "s-def"
  end

  test "forgetting a uri with no memory reports that none was found" do
    assert {:error, :no_memory} =
             AgentDb.forget("viking://user/memories/preferences/never-recorded")
  end

  test "forgetting an ordinary document leaves it alone" do
    :ok = AgentDb.write("viking://resources/notes/a.md", "just a document")

    assert {:error, :no_memory} = AgentDb.forget("viking://resources/notes/a.md")
    assert {:ok, "just a document"} = AgentDb.read("viking://resources/notes/a.md")
  end

  test "removing a subtree discards the memory rows beneath it" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")
    {:ok, _} = AgentDb.remember("viking://user/memories/preferences/ui/theme", "dark")

    assert :ok = AgentDb.rm("viking://user/memories/preferences")

    assert {:ok, [0]} = count_memory_meta("viking://user/memories/preferences")
    assert {:ok, [0]} = count_memory_meta("viking://user/memories/preferences/ui/theme")
  end

  # -- memories are ordinary tree documents --

  test "a memory appears in tree navigation" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")

    assert {:ok, types} = AgentDb.list("viking://user/memories")
    assert "preferences" in types

    assert {:ok, slots} = AgentDb.list("viking://user/memories/preferences")
    assert slots == ["language"]

    assert {:ok, tree} = AgentDb.tree("viking://user/memories", 3)
    assert tree.children |> Enum.map(& &1.name) == ["preferences"]
  end

  test "a memory is term-searchable through ordinary search" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Zsh over Bash")

    assert {:ok, [hit]} = AgentDb.search("Zsh", mode: :keyword, scope: "viking://user/memories")
    assert hit.uri == @lang
  end

  test "recording enqueues embedding but no summarization" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir")

    assert {:ok, [1]} = count_jobs(@lang, "embed")
    assert {:ok, [0]} = count_jobs(@lang, "summarize_abstract")
    assert {:ok, [0]} = count_jobs(@lang, "summarize_overview")
  end

  test "recording without its embedding job leaves nothing behind" do
    # Take the queue away mid-flight: the document and the assertion are
    # already written when the enqueue fails, and the write is one outcome,
    # so none of them survives the rollback.
    restore = break_queue()

    try do
      assert {:error, _reason} = AgentDb.remember(@lang, "prefers Vim")
    after
      restore.()
    end

    assert {:ok, []} = AgentDb.recall(@lang)
    assert {:error, :not_found} = AgentDb.read(@lang)
  end

  test "recording and recall work with no model loaded" do
    assert %{embedding: %{loaded: false}, llm: %{loaded: false}} = ModelManager.model_status()

    assert {:ok, @lang} = AgentDb.remember(@lang, "prefers Elixir")
    assert {:ok, [memory]} = AgentDb.recall(term: "Elixir")
    assert memory.value == "prefers Elixir"
  end

  test "a memory survives a restart" do
    {:ok, _} = AgentDb.remember(@lang, "prefers Elixir", confidence: 0.9, source: "s-abc")
    restart_app()

    assert {:ok, [memory]} = AgentDb.recall(@lang)
    assert memory.value == "prefers Elixir"
    assert memory.confidence == 0.9
    assert memory.source == "s-abc"
  end

  test "a revised memory keeps its history across a restart" do
    {:ok, _} = AgentDb.remember(@lang, "user uses Go")
    {:ok, _} = AgentDb.remember(@lang, "user moved to Elixir")
    restart_app()

    assert {:ok, [active]} = AgentDb.recall(@lang)
    assert active.value == "user moved to Elixir"

    assert {:ok, history} = AgentDb.recall(uri: @lang, include_superseded: true)
    assert Enum.any?(history, &(&1.value == "user uses Go" and &1.status == :superseded))
  end

  # -- helpers --

  # Takes the job queue away, so an enqueue fails after the document and the
  # assertion have already been written, and puts it back. The table is renamed
  # rather than dropped, so work already queued before the break is still there
  # to be drained when the queue returns.
  defp break_queue do
    rename = fn statement ->
      AgentDb.Store.Writer.call(fn conn -> SQLite.exec(conn, statement) end)
    end

    rename.("ALTER TABLE job_queue RENAME TO job_queue_missing")

    fn -> rename.("ALTER TABLE job_queue_missing RENAME TO job_queue") end
  end

  defp count_memory_meta(uri) do
    Reader.read(fn conn ->
      SQLite.query_one(
        conn,
        "SELECT COUNT(*) FROM memory_meta WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
        [uri, AgentDb.Store.Nodes.like_escape(uri <> "/") <> "%"]
      )
    end)
  end

  # Rows are never deleted from job_queue -- completion sets status='done' -- so
  # counting by kind is deterministic even while workers are draining.
  defp count_jobs(uri, kind) do
    Reader.read(fn conn ->
      SQLite.query_one(
        conn,
        "SELECT COUNT(*) FROM job_queue WHERE kind = ?1 AND json_extract(payload, '$.uri') = ?2",
        [kind, uri]
      )
    end)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
