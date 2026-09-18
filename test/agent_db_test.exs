defmodule AgentDbTest do
  use ExUnit.Case, async: false

  alias AgentDb.Cache.Owner

  setup do
    Owner.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  # -- write/read round trip --

  test "write persists content and read returns identical content" do
    assert :ok =
             AgentDb.write(
               "viking://resources/my_project/docs/api.md",
               "# API docs\n\nHello viking"
             )

    assert {:ok, "# API docs\n\nHello viking"} =
             AgentDb.read("viking://resources/my_project/docs/api.md")
  end

  test "read of missing URI returns not_found without side effects" do
    assert {:error, :not_found} = AgentDb.read("viking://resources/does_not_exist")
    assert {:error, :not_found} = AgentDb.list("viking://resources/does_not_exist")
    assert {:error, :not_found} = AgentDb.rm("viking://resources/does_not_exist")
  end

  test "listing reflects writes" do
    :ok = AgentDb.write("viking://resources/p/docs/a.md", "aaa")
    :ok = AgentDb.write("viking://resources/p/docs/b.md", "bbb")

    assert {:ok, names} = AgentDb.list("viking://resources/p/docs")
    assert Enum.sort(names) == ["a.md", "b.md"]
  end

  test "invalid URIs are rejected" do
    assert {:error, :invalid_uri} = AgentDb.write("http://nope/x", "c")
    assert {:error, :invalid_uri} = AgentDb.read("viking://a/../b")
    assert {:error, :invalid_uri} = AgentDb.read("viking://a//b")
    assert {:error, :invalid_uri} = AgentDb.read("viking://a/./b")
    assert {:error, :invalid_uri} = AgentDb.write("viking://ok/seg\\bad", "c")
    assert {:error, :invalid_uri} = AgentDb.write("viking://ok/seg\0x", "c")
  end

  # -- layered content --

  test "abstract returns caller-supplied L0 verbatim" do
    :ok = AgentDb.write("viking://resources/doc1.md", "full body", abstract: "one-line L0")

    assert {:ok, "one-line L0"} = AgentDb.abstract("viking://resources/doc1.md")
  end

  test "abstract falls back to first non-empty line" do
    :ok = AgentDb.write("viking://resources/doc2.md", "\n  second line is first non-empty \nbody")

    assert {:ok, "second line is first non-empty"} =
             AgentDb.abstract("viking://resources/doc2.md")
  end

  test "overview returns caller-supplied L1 verbatim" do
    :ok = AgentDb.write("viking://resources/doc3.md", "body", overview: "structured L1")

    assert {:ok, "structured L1"} = AgentDb.overview("viking://resources/doc3.md")
  end

  test "overview falls back to first 280 chars of content" do
    long = String.duplicate("x", 400)
    expected = String.duplicate("x", 280)
    :ok = AgentDb.write("viking://resources/doc4.md", long)

    assert {:ok, ^expected} = AgentDb.overview("viking://resources/doc4.md")
  end

  # -- persist-before-cache --

  test "cache path matches SQLite fallback path after write" do
    :ok = AgentDb.write("viking://resources/cached.md", "same everywhere", abstract: "abs")

    # warm the cache
    {:ok, via_cache} = AgentDb.read("viking://resources/cached.md")

    # force cold read straight from SQLite through the reader pool
    uri = "viking://resources/cached.md"

    {:ok, cold} =
      AgentDb.Store.Reader.read(fn conn ->
        case AgentDb.Store.Nodes.get(conn, uri) do
          {:ok, node} -> {:ok, node.content}
          other -> other
        end
      end)

    assert via_cache == cold
  end

  # -- rm --

  test "rm removes subtree from SQLite and cache" do
    :ok = AgentDb.write("viking://resources/sub/x/a.md", "ax")
    :ok = AgentDb.write("viking://resources/sub/y.md", "y")

    # warm caches
    {:ok, _} = AgentDb.read("viking://resources/sub/x/a.md")
    {:ok, _} = AgentDb.list("viking://resources/sub")

    assert :ok = AgentDb.rm("viking://resources/sub")

    assert {:error, :not_found} = AgentDb.read("viking://resources/sub/y.md")
    assert {:error, :not_found} = AgentDb.read("viking://resources/sub/x/a.md")
    assert {:error, :not_found} = AgentDb.list("viking://resources/sub")

    # SQLite has no leftover rows
    assert {:ok, [[0]]} =
             AgentDb.Store.Reader.read(fn conn ->
               AgentDb.Store.SQLite.query(conn, "SELECT COUNT(*) FROM nodes WHERE uri LIKE ?", [
                 "viking://resources/sub%"
               ])
             end)
  end

  # -- tree --

  test "tree returns depth-limited structure" do
    :ok = AgentDb.write("viking://resources/t/a/b/deep.md", "deep")
    :ok = AgentDb.write("viking://resources/t/top.md", "top", abstract: "t0")

    {:ok, t1} = AgentDb.tree("viking://resources/t", 1)
    assert %{type: :dir, children: _} = t1

    {:ok, t2} = AgentDb.tree("viking://resources/t", 2)
    child_names = Enum.map(t2.children, & &1.name)
    assert Enum.sort(child_names) == ["a", "top.md"]
  end

  # -- Search --

  test "search finds case-insensitive substring in content" do
    :ok = AgentDb.write("viking://resources/a.md", "The quick brown fox")
    :ok = AgentDb.write("viking://resources/b.md", "Lazy dog sleeps")

    assert {:ok, results} = AgentDb.search("FOX")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/a.md"

    assert {:ok, results} = AgentDb.search("SLEEPS")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/b.md"
  end

  test "search scoped to subtree" do
    :ok = AgentDb.write("viking://resources/p/x.md", "needle in haystack")
    :ok = AgentDb.write("viking://resources/q/y.md", "needle in other")

    assert {:ok, results} = AgentDb.search("needle", scope: "viking://resources/p")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/p/x.md"

    assert {:ok, results} = AgentDb.search("needle", scope: "viking://resources/q")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/q/y.md"
  end

  test "search matches abstract and overview too" do
    :ok =
      AgentDb.write("viking://resources/s.md", "body content",
        abstract: "short abstract",
        overview: "detailed overview"
      )

    assert {:ok, results} = AgentDb.search("abstract")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/s.md"

    assert {:ok, results} = AgentDb.search("overview")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/s.md"
  end

  # -- Sessions --

  test "create_session returns unique id" do
    {:ok, id1} = AgentDb.create_session()
    {:ok, id2} = AgentDb.create_session()

    assert is_binary(id1)
    assert is_binary(id2)
    assert id1 != id2
  end

  test "append_message preserves order and role" do
    {:ok, sid} = AgentDb.create_session()

    :ok = AgentDb.append_message(sid, :user, "hello")
    :ok = AgentDb.append_message(sid, :assistant, "hi there")
    :ok = AgentDb.append_message(sid, :user, "how are you?")

    {:ok, msgs} = AgentDb.get_session(sid)
    assert length(msgs) == 3
    assert Enum.map(msgs, & &1.role) == [:user, :assistant, :user]
    assert Enum.map(msgs, & &1.content) == ["hello", "hi there", "how are you?"]
  end

  test "session survives restart" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "persist me")

    # restart the whole app
    restart_app()

    {:ok, msgs} = AgentDb.get_session(sid)
    assert length(msgs) == 1
    assert hd(msgs).content == "persist me"
  end

  # -- Commit session to context --

  test "commit_session writes session as document" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "first")
    :ok = AgentDb.append_message(sid, :assistant, "second")

    {:ok, dest} = AgentDb.commit_session(sid, "viking://user/u1/memories/session-1")

    assert dest == "viking://user/u1/memories/session-1"
    assert {:ok, content} = AgentDb.read(dest)
    assert String.contains?(content, "user: first")
    assert String.contains?(content, "assistant: second")
  end

  test "commit_session idempotent: re-commit without new messages is no-op" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "msg")

    {:ok, dest1} = AgentDb.commit_session(sid, "viking://user/u1/memories/commit-test")
    {:ok, dest2} = AgentDb.commit_session(sid, "viking://user/u1/memories/commit-test")

    assert dest1 == dest2
    assert dest1 == "viking://user/u1/memories/commit-test"

    # only one document exists
    assert {:ok, content} = AgentDb.read(dest1)
    assert String.contains?(content, "msg")
  end

  test "commit_session creates new document when session has new messages" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "v1")

    {:ok, _} = AgentDb.commit_session(sid, "viking://user/u1/memories/v")
    :ok = AgentDb.append_message(sid, :assistant, "v2")

    {:ok, dest} = AgentDb.commit_session(sid, "viking://user/u1/memories/v")

    assert dest == "viking://user/u1/memories/v"
    assert {:ok, content} = AgentDb.read(dest)
    assert String.contains?(content, "v1")
    assert String.contains?(content, "v2")
  end

  test "commit_session creates parent directories implicitly" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "deep")

    {:ok, dest} = AgentDb.commit_session(sid, "viking://user/u1/memories/a/b/c/session.md")

    assert dest == "viking://user/u1/memories/a/b/c/session.md"
    assert {:ok, content} = AgentDb.read(dest)
    assert String.contains?(content, "deep")
  end

  # -- System verification: restart recovery --

  test "full system restart recovery: documents, sessions, search survive restart" do
    # Phase 1: populate the store with various data
    :ok =
      AgentDb.write("viking://resources/project/readme.md", "# Project\n\nMain documentation",
        abstract: "Project root",
        overview: "Overview of project"
      )

    :ok =
      AgentDb.write(
        "viking://resources/project/src/main.ex",
        "defmodule Main do\n  def run, do: :ok", abstract: "Entry point")

    :ok =
      AgentDb.write("viking://user/alice/memories/pref.md", "Prefers dark mode",
        overview: "User preference"
      )

    :ok =
      AgentDb.write("viking://user/bob/skills/search.ex", "def search(q), do: :ok",
        abstract: "Search skill"
      )

    {:ok, sid1} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid1, :user, "Hello")
    :ok = AgentDb.append_message(sid1, :assistant, "Hi there")
    {:ok, _} = AgentDb.commit_session(sid1, "viking://user/alice/memories/session-1")

    {:ok, sid2} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid2, :user, "Remember this")
    :ok = AgentDb.append_message(sid2, :assistant, "Got it")
    {:ok, _} = AgentDb.commit_session(sid2, "viking://user/bob/memories/session-2")

    # Warm caches by reading
    {:ok, _} = AgentDb.read("viking://resources/project/readme.md")
    {:ok, _} = AgentDb.read("viking://resources/project/src/main.ex")
    {:ok, _} = AgentDb.read("viking://user/alice/memories/pref.md")
    {:ok, _} = AgentDb.list("viking://resources/project")
    {:ok, _} = AgentDb.search("documentation")
    {:ok, _} = AgentDb.search("prefers", scope: "viking://user/alice")

    # Phase 2: restart the entire application
    restart_app()

    # Phase 3: verify all data survived
    # Documents
    assert {:ok, "# Project\n\nMain documentation"} =
             AgentDb.read("viking://resources/project/readme.md")

    assert {:ok, "defmodule Main do\n  def run, do: :ok"} =
             AgentDb.read("viking://resources/project/src/main.ex")

    assert {:ok, "Prefers dark mode"} = AgentDb.read("viking://user/alice/memories/pref.md")
    assert {:ok, "def search(q), do: :ok"} = AgentDb.read("viking://user/bob/skills/search.ex")

    # Abstracts/overviews (with fallbacks)
    assert {:ok, "Project root"} = AgentDb.abstract("viking://resources/project/readme.md")
    assert {:ok, "Overview of project"} = AgentDb.overview("viking://resources/project/readme.md")
    assert {:ok, "Entry point"} = AgentDb.abstract("viking://resources/project/src/main.ex")
    assert {:ok, "User preference"} = AgentDb.overview("viking://user/alice/memories/pref.md")
    assert {:ok, "Search skill"} = AgentDb.abstract("viking://user/bob/skills/search.ex")

    # Sessions
    {:ok, msgs1} = AgentDb.get_session(sid1)
    assert length(msgs1) == 2
    assert Enum.map(msgs1, & &1.content) == ["Hello", "Hi there"]

    {:ok, msgs2} = AgentDb.get_session(sid2)
    assert length(msgs2) == 2
    assert Enum.map(msgs2, & &1.content) == ["Remember this", "Got it"]

    # Committed session documents
    assert {:ok, content1} = AgentDb.read("viking://user/alice/memories/session-1")
    assert String.contains?(content1, "user: Hello")
    assert String.contains?(content1, "assistant: Hi there")

    assert {:ok, content2} = AgentDb.read("viking://user/bob/memories/session-2")
    assert String.contains?(content2, "user: Remember this")
    assert String.contains?(content2, "assistant: Got it")

    # Search still works
    assert {:ok, results} = AgentDb.search("documentation")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/project/readme.md"

    assert {:ok, results} = AgentDb.search("prefers", scope: "viking://user/alice")
    assert length(results) == 1
    assert hd(results).uri == "viking://user/alice/memories/pref.md"

    assert {:ok, results} = AgentDb.search("entry")
    assert length(results) == 1
    assert hd(results).uri == "viking://resources/project/src/main.ex"

    # Tree listings
    assert {:ok, names} = AgentDb.list("viking://resources/project")
    assert Enum.sort(names) == ["readme.md", "src"]
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
