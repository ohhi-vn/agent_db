defmodule AgentDbTest do
  use ExUnit.Case, async: false

  alias AgentDb.Cache

  setup do
    Cache.clear()
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

    # Every URI-keyed store must be clean, not just `nodes`. vec_nodes only
    # exists when the sqlite-vec extension loaded.
    assert {:ok, [0]} = count_rows("nodes", "uri", "viking://resources/sub")
    assert {:ok, [0]} = count_rows("job_queue", :payload_uri, "viking://resources/sub")

    assert {:ok, [0]} =
             count_rows("commit_meta", "destination_uri", "viking://resources/sub")

    if match?({:ok, true}, table_exists?("vec_nodes")) do
      assert {:ok, [0]} = count_rows("vec_nodes", "uri", "viking://resources/sub")
    end
  end

  # Vector-search behaviour is only observable when the sqlite-vec extension
  # loaded and vec_nodes exists. Where it is unavailable these scenarios are
  # inert; the store-level half of the same invariant (removal leaves nothing
  # behind, and a recreated URI starts clean) is covered by the tests above.
  test "a recreated URI is not searchable on the removed node's embedding" do
    if match?({:ok, true}, table_exists?("vec_nodes")) do
      uri = "viking://resources/recreate/a.md"
      :ok = AgentDb.write(uri, "kubernetes scheduler internals", async: false)
      assert {:ok, [%{uri: ^uri} | _]} = vector_search("viking://resources/recreate", "scheduler")

      assert :ok = AgentDb.rm("viking://resources/recreate")

      # A different document at the same URI must not inherit the old embedding.
      :ok = AgentDb.write(uri, "entirely unrelated subject matter", async: false)
      assert {:ok, results} = vector_search("viking://resources/recreate", "scheduler")
      assert results == []

      # Once its own embedding lands, it is searchable on its own merits.
      :ok = AgentDb.write(uri, "entirely unrelated subject matter", async: false)
      assert {:ok, [_ | _]} = vector_search("viking://resources/recreate", "unrelated")
    end
  end

  test "rm works on a store opened without the sqlite-vec extension" do
    # vec_nodes does not exist in this environment, so this exercises the
    # degraded path: the purge must skip the vector index and still leave the
    # node store, job queue, and commit bookkeeping consistent.
    refute match?({:ok, true}, table_exists?("vec_nodes"))

    :ok = AgentDb.write("viking://resources/nov/deep/a.md", "distinctivenovectorword")
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "hello")
    {:ok, _} = AgentDb.commit_session(sid, "viking://resources/nov/deep/committed")

    assert :ok = AgentDb.rm("viking://resources/nov")

    assert {:error, :not_found} = AgentDb.read("viking://resources/nov/deep/a.md")
    assert {:ok, results} = AgentDb.search("distinctivenovectorword")
    assert results == []

    # The other three stores are still purged.
    assert {:ok, [0]} = count_rows("nodes", "uri", "viking://resources/nov")
    assert {:ok, [0]} = count_rows("job_queue", :payload_uri, "viking://resources/nov")
    assert {:ok, [0]} = count_rows("commit_meta", "destination_uri", "viking://resources/nov")
  end

  test "ensure_schema leaves a clean database untouched" do
    :ok = AgentDb.write("viking://resources/clean/a.md", "content")

    # Idempotent: repeated boots must not remove or alter live rows.
    path = Path.join(AgentDb.Config.data_dir(), "agent_db.db")
    {:ok, conn} = AgentDb.Store.SQLite.open(path)
    assert :ok = AgentDb.Store.SQLite.ensure_schema(conn)
    assert :ok = AgentDb.Store.SQLite.ensure_schema(conn)
    :ok = AgentDb.Store.SQLite.close(conn)

    assert {:ok, "content"} = AgentDb.read("viking://resources/clean/a.md")
    assert {:ok, [1]} = count_rows("nodes", "uri", "viking://resources/clean/a.md")
  end

  test "rm cancels queued jobs for the removed subtree" do
    uri = "viking://resources/jobbed/a.md"
    :ok = AgentDb.write(uri, "content to embed")
    outside = "viking://resources/keep/b.md"
    :ok = AgentDb.write(outside, "other content")

    # The write enqueued embed + summarization jobs for `uri`.
    assert {:ok, before} = jobs_for(uri)
    assert before > 0

    assert :ok = AgentDb.rm("viking://resources/jobbed")

    assert {:ok, [0]} = jobs_for(uri)
  end

  test "rm leaves a removed subtree unsearchable" do
    :ok = AgentDb.write("viking://resources/gone/x.md", "distinctiveneedlyword")

    assert {:ok, results} = AgentDb.search("distinctiveneedlyword")
    assert length(results) == 1

    assert :ok = AgentDb.rm("viking://resources/gone")

    assert {:ok, results} = AgentDb.search("distinctiveneedlyword")
    assert results == []
  end

  test "rm of a missing URI returns not_found and writes nothing" do
    :ok = AgentDb.write("viking://resources/present.md", "keep me")

    assert {:error, :not_found} = AgentDb.rm("viking://resources/absent")

    assert {:ok, "keep me"} = AgentDb.read("viking://resources/present.md")
    assert {:ok, [0]} = count_rows("nodes", "uri", "viking://resources/absent")
  end

  test "rm of the tree root is rejected and leaves the tree intact" do
    :ok = AgentDb.write("viking://resources/stays/a.md", "still here")

    assert {:error, :is_root} = AgentDb.rm("viking://")

    assert {:ok, "still here"} = AgentDb.read("viking://resources/stays/a.md")
  end

  test "rm of a top-level subtree succeeds and leaves siblings alone" do
    :ok = AgentDb.write("viking://resources/p/a.md", "in resources")
    :ok = AgentDb.write("viking://user/u1/memories/m.md", "in memories")

    assert :ok = AgentDb.rm("viking://resources")

    assert {:error, :not_found} = AgentDb.read("viking://resources/p/a.md")
    assert {:ok, "in memories"} = AgentDb.read("viking://user/u1/memories/m.md")
    assert {:ok, _} = AgentDb.list("viking://user/u1/memories")
  end

  test "cached reads and store reads agree after rm" do
    :ok = AgentDb.write("viking://resources/cachesub/a.md", "cached content")

    # Warm both the node cache and the dir cache.
    assert {:ok, "cached content"} = AgentDb.read("viking://resources/cachesub/a.md")
    assert {:ok, ["a.md"]} = AgentDb.list("viking://resources/cachesub")

    assert :ok = AgentDb.rm("viking://resources/cachesub")

    # Both paths must report not_found, and a cold read must agree.
    assert {:error, :not_found} = AgentDb.read("viking://resources/cachesub/a.md")
    assert {:error, :not_found} = AgentDb.list("viking://resources/cachesub")

    assert {:ok, nil} =
             AgentDb.Store.Reader.read(fn conn ->
               AgentDb.Store.Nodes.get(conn, "viking://resources/cachesub/a.md")
             end)
  end

  test "rm rolls back every store when one delete fails" do
    :ok = AgentDb.write("viking://resources/atomic/a.md", "content")
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "hello")
    {:ok, _} = AgentDb.commit_session(sid, "viking://resources/atomic/committed")

    # Force a delete late in the purge to fail. Without a transaction the
    # nodes rows and the job cancellations are already committed by the time
    # the failure is reached, leaving the subtree half-removed.
    assert :ok =
             AgentDb.Store.Writer.call(fn conn ->
               AgentDb.Store.SQLite.exec(conn, "DROP TABLE job_queue")
             end)

    try do
      assert {:error, _} = AgentDb.rm("viking://resources/atomic")
    after
      assert :ok =
               AgentDb.Store.Writer.call(fn conn ->
                 AgentDb.Store.SQLite.ensure_schema(conn)
               end)
    end

    # Nothing was removed, in any store.
    assert {:ok, "content"} = AgentDb.read("viking://resources/atomic/a.md")
    assert {:ok, [1]} = count_rows("commit_meta", "destination_uri", "viking://resources/atomic")
    assert {:ok, [1]} = count_rows("nodes", "uri", "viking://resources/atomic/committed")
  end

  # -- rm + session commit --

  test "re-committing an unchanged session restores a removed destination" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "Remember this")
    :ok = AgentDb.append_message(sid, :assistant, "Got it")

    dest = "viking://user/u1/memories/session-restore"
    assert {:ok, ^dest} = AgentDb.commit_session(sid, dest)

    assert :ok = AgentDb.rm("viking://user/u1/memories/session-restore")
    assert {:error, :not_found} = AgentDb.read(dest)

    # The old content_hash is gone with the destination, so the commit must
    # report the URI and rebuild the document rather than claiming :unchanged.
    assert {:ok, ^dest} = AgentDb.commit_session(sid, dest)

    assert {:ok, content} = AgentDb.read(dest)
    assert String.contains?(content, "user: Remember this")
    assert String.contains?(content, "assistant: Got it")

    # Restored, not duplicated.
    assert {:ok, [dest]} = AgentDb.list("viking://user/u1/memories")
  end

  test "rm clears only the removed destination's commit bookkeeping" do
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "shared message")

    removed = "viking://user/u1/memories/gone"
    kept = "viking://user/u1/memories/kept"

    {:ok, ^removed} = AgentDb.commit_session(sid, removed)
    {:ok, ^kept} = AgentDb.commit_session(sid, kept)

    assert :ok = AgentDb.rm(removed)

    # The surviving destination keeps its hash, so it is still idempotent.
    assert {:ok, :unchanged} = AgentDb.commit_session(sid, kept)
    assert {:ok, _} = AgentDb.read(kept)

    # A different destination is unaffected too.
    other = "viking://user/u1/memories/other"
    assert {:ok, ^other} = AgentDb.commit_session(sid, other)
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

  test "list returns direct children only, not grandchildren" do
    :ok = AgentDb.write("viking://resources/p/docs/a.md", "grandchild content")
    :ok = AgentDb.write("viking://resources/p/readme.md", "child content")

    assert {:ok, names} = AgentDb.list("viking://resources/p")
    assert Enum.sort(names) == ["docs", "readme.md"]
    refute "a.md" in names
  end

  test "list of a missing URI returns not_found and writes nothing" do
    assert {:error, :not_found} = AgentDb.list("viking://resources/no_such_dir")
    assert {:ok, [0]} = count_rows("nodes", "uri", "viking://resources/no_such_dir")
  end

  test "tree depth 1 stops at direct children" do
    :ok = AgentDb.write("viking://resources/depth/a/b/deep.md", "deep")

    # At depth 1 children are bare names: the projection stops there, so `b`
    # and `deep.md` cannot appear.
    {:ok, t1} = AgentDb.tree("viking://resources/depth", 1)
    assert t1.children == ["a"]

    {:ok, t2} = AgentDb.tree("viking://resources/depth", 2)
    assert [a] = t2.children
    assert a.name == "a"
    # Depth 2 expands one level past the child, as bare names.
    assert a.children == ["b"]
  end

  test "tree of a missing URI returns not_found and writes nothing" do
    assert {:error, :not_found} = AgentDb.tree("viking://resources/no_such_dir")
    assert {:ok, [0]} = count_rows("nodes", "uri", "viking://resources/no_such_dir")
  end

  test "tree reflects a prior removal" do
    :ok = AgentDb.write("viking://resources/rmtree/a/b/deep.md", "deep")
    :ok = AgentDb.write("viking://resources/rmtree/keep.md", "keep")

    {:ok, before} = AgentDb.tree("viking://resources/rmtree", 2)
    assert Enum.sort(Enum.map(before.children, & &1.name)) == ["a", "keep.md"]

    assert :ok = AgentDb.rm("viking://resources/rmtree/a")

    {:ok, after_rm} = AgentDb.tree("viking://resources/rmtree", 2)
    assert Enum.map(after_rm.children, & &1.name) == ["keep.md"]

    names = collect_tree_names(after_rm)
    refute "b" in names
    refute "deep.md" in names
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

  # -- sync write honesty --

  # A failed background job used to be invisible to write(async: false): the
  # pending count excluded 'failed', so the queue looked idle and the write
  # reported success having accomplished nothing.
  test "a synchronous write reports failure rather than success" do
    uri = "viking://resources/syncfail/a.md"

    # The write enqueues its own jobs, so the outcome has to be driven against
    # those. A task fails every job for the URI as it appears; the wait then
    # sees nothing active but at least one failure.
    task =
      Task.async(fn ->
        fail_all_jobs_for(uri, 2_000)
      end)

    assert {:error, {:background_jobs_failed, ^uri}} =
             AgentDb.write(uri, "content", async: false, sync_timeout_ms: 3_000)

    Task.await(task, 5_000)
  end

  test "a synchronous write reports work still outstanding rather than success" do
    uri = "viking://resources/syncpending/a.md"

    # Nothing consumes these jobs, so the wait reaches its deadline with work
    # still active. This is the state a store with no available model is in,
    # since jobs defer rather than fail.
    assert {:error, {:background_jobs_pending, ^uri}} =
             AgentDb.write(uri, "content", async: false, sync_timeout_ms: 200)
  end

  test "a completed background job still reports success" do
    uri = "viking://resources/syncdone/a.md"

    task = Task.async(fn -> complete_all_jobs_for(uri, 2_000) end)

    assert :ok = AgentDb.write(uri, "content", async: false, sync_timeout_ms: 3_000)

    Task.await(task, 5_000)
  end

  # Drives the outcome of the jobs a sync write enqueues, which the write itself
  # blocks on. It must keep acting across rounds: the application's own workers
  # claim jobs and defer them back to pending, so a single pass over the queue
  # is not enough.
  defp settle_jobs_for(uri, action, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_settle_jobs_for(uri, action, deadline, 0, 0)
  end

  defp do_settle_jobs_for(uri, action, deadline, acted, empty_rounds) do
    ids = job_ids_for(uri)
    expired? = System.monotonic_time(:millisecond) >= deadline

    cond do
      ids != [] ->
        Enum.each(ids, action)
        if expired?, do: :ok, else: do_settle_jobs_for(uri, action, deadline, acted + 1, 0)

      # Nothing left to settle, confirmed over consecutive polls so a job that
      # is merely between claim and defer is not mistaken for a settled one.
      acted > 0 and empty_rounds >= 3 ->
        :ok

      expired? ->
        :ok

      true ->
        Process.sleep(20)
        do_settle_jobs_for(uri, action, deadline, acted, empty_rounds + 1)
    end
  end

  # Both pending and running jobs are looked for. A job a worker is midway
  # through is already spent, and acting on it would race the worker to decide
  # its outcome.
  defp job_ids_for(uri) do
    AgentDb.Store.Reader.read(fn conn ->
      case AgentDb.Store.SQLite.query(
             conn,
             "SELECT id FROM job_queue WHERE json_extract(payload, '$.uri') = ?1 AND status = 'pending'",
             [uri]
           ) do
        {:ok, rows} -> Enum.map(rows, &hd/1)
        _ -> []
      end
    end)
  end

  # A job only lands in 'failed' once its attempt budget is exhausted, and the
  # backoff between attempts is seconds. Zeroing each job's budget makes a
  # single failure terminal whatever its current attempt count -- at
  # max_attempts 1 a job that has not been claimed yet would still reschedule,
  # since 0 < 1. The cap is applied per job as it is found, because the write
  # enqueues them concurrently with this task.
  defp fail_all_jobs_for(uri, timeout_ms) do
    settle_jobs_for(
      uri,
      fn job_id ->
        cap_attempts(job_id, 0)
        AgentDb.Adapters.SQLite.fail_job(job_id)
      end,
      timeout_ms
    )
  end

  defp complete_all_jobs_for(uri, timeout_ms) do
    settle_jobs_for(uri, &AgentDb.Adapters.SQLite.complete_job/1, timeout_ms)
  end

  defp cap_attempts(job_id, max_attempts) do
    AgentDb.Store.Writer.call(fn conn ->
      AgentDb.Store.SQLite.exec_write(
        conn,
        "UPDATE job_queue SET max_attempts = ?1 WHERE id = ?2",
        [max_attempts, job_id]
      )
    end)
  end

  # -- unservable operations --

  test "a search that needs an unavailable model reports an error, not a crash" do
    :ok = AgentDb.write("viking://resources/novm/a.md", "content")

    # No model is cached and remote downloads are skipped under test, so vector
    # search cannot be served. It must say so rather than terminating the
    # caller, which is what the WebSocket gateway forwards to clients.
    assert {:error, {:model_not_found, _path}} =
             AgentDb.search("content", mode: :vector)

    # The caller survives, and unrelated operations still work.
    assert {:ok, _} = AgentDb.read("viking://resources/novm/a.md")
    assert {:ok, [_]} = AgentDb.search("content", mode: :keyword)
  end

  test "a hybrid search that needs an unavailable model reports an error, not a crash" do
    :ok = AgentDb.write("viking://resources/novm2/a.md", "content")

    assert {:error, {:model_not_found, _path}} = AgentDb.search("content", mode: :hybrid)
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

    dest = "viking://user/u1/memories/commit-test"
    {:ok, ^dest} = AgentDb.commit_session(sid, dest)

    # An unchanged session converges on the existing document and reports that
    # it did so, rather than reporting the URI as if it had just written it.
    assert {:ok, :unchanged} = AgentDb.commit_session(sid, dest)

    # only one document exists
    assert {:ok, content} = AgentDb.read(dest)
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

  test "commit_session invalidates the cache for its destination" do
    dest = "viking://user/u1/memories/cached"
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "first")

    {:ok, ^dest} = AgentDb.commit_session(sid, dest)

    # Populates the ETS read-through entry for dest.
    assert {:ok, before} = AgentDb.read(dest)
    assert String.contains?(before, "first")

    :ok = AgentDb.append_message(sid, :assistant, "second")
    {:ok, ^dest} = AgentDb.commit_session(sid, dest)

    # A warm cache would still hold the pre-commit content here.
    assert {:ok, cached_read} = AgentDb.read(dest)
    assert String.contains?(cached_read, "second")

    # ...and it matches what a cold cache produces from SQLite.
    Cache.clear()
    assert {:ok, cold_read} = AgentDb.read(dest)
    assert cold_read == cached_read
  end

  test "commit_session that is :unchanged leaves the cache serving the same content" do
    dest = "viking://user/u1/memories/unchanged"
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "only")

    {:ok, ^dest} = AgentDb.commit_session(sid, dest)
    assert {:ok, first} = AgentDb.read(dest)

    assert {:ok, :unchanged} = AgentDb.commit_session(sid, dest)
    assert {:ok, second} = AgentDb.read(dest)

    assert first == second
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
        "defmodule Main do\n  def run, do: :ok",
        abstract: "Entry point"
      )

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

  # Counts rows in a URI-keyed store whose key starts with `prefix`.
  # `column` is a column name, or :payload_uri for job_queue's JSON payload.
  # Runs a vector search, tolerating a store with no vector index.
  defp vector_search(scope, term) do
    AgentDb.search(term, mode: :vector, scope: scope)
  end

  # Reads through the writer's connection: every row these assertions inspect was
  # written there, so asserting on any other connection would also be asserting
  # on cross-connection visibility rather than on the behaviour under test.
  defp count_rows(table, column, prefix) do
    col = if column == :payload_uri, do: "json_extract(payload, '$.uri')", else: column

    AgentDb.Store.Writer.call(fn conn ->
      AgentDb.Store.SQLite.query_one(
        conn,
        "SELECT COUNT(*) FROM #{table} WHERE #{col} = ?1 OR #{col} LIKE ?2 ESCAPE '\\'",
        [prefix, AgentDb.Store.Nodes.like_escape(prefix) <> "/%"]
      )
    end)
  end

  # Number of still-unfinished jobs targeting `uri` (exact or descendant).
  defp jobs_for(uri) do
    AgentDb.Store.Writer.call(fn conn ->
      AgentDb.Store.SQLite.query_one(
        conn,
        """
        SELECT COUNT(*) FROM job_queue
        WHERE (json_extract(payload, '$.uri') = ?1
               OR json_extract(payload, '$.uri') LIKE ?2 ESCAPE '\\')
          AND status IN ('pending', 'running')
        """,
        [uri, AgentDb.Store.Nodes.like_escape(uri) <> "/%"]
      )
    end)
  end

  defp table_exists?(table) do
    AgentDb.Store.Writer.call(fn conn ->
      case AgentDb.Store.SQLite.query_one(
             conn,
             "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
             [table]
           ) do
        {:ok, nil} -> {:ok, false}
        {:ok, _} -> {:ok, true}
      end
    end)
  end

  defp collect_tree_names(entry) do
    children = Map.get(entry, :children) || []

    Enum.flat_map(children, fn child ->
      [child.name] ++ collect_tree_names(child)
    end)
  end
end
