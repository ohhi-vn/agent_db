defmodule AgentDb.StorageContract.Helpers do
  @moduledoc false
  # Lifecycle the storage contract suite needs: a store of its own to run
  # against, and no workers racing its assertions.

  def restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  @doc """
  Puts the store back the way it was: running, with `child` under its
  supervisor.

  Two things a test cannot assume. The application may already be stopped, by
  this test or by an earlier file's teardown, and the supervisor this reaches
  for only exists while it runs. And a test that started the same child itself
  holds it under the test's own supervisor, which is torn down asynchronously --
  so the name may still be taken when this runs, and the restoration deferred
  until it is not.
  """
  def restore_child(child) do
    case Application.ensure_all_started(:agent_db) do
      {:ok, _apps} ->
        if child in [AgentDb.Workers.Embedding, AgentDb.Workers.Summarization] do
          restore_workers(child)
        else
          restart_when_free(child)
        end

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp restore_workers(handler) do
    for {id, _, _, _} <- worker_children(handler) do
      restart_when_free(id)
    end

    :ok
  end

  # A name conflict here means the test's own copy of the child is still
  # shutting down. Retrying briefly is enough; waiting forever would hang the
  # suite on a process that is already going.
  defp restart_when_free(child, attempts \\ 20)

  defp restart_when_free(_child, 0), do: :ok

  defp restart_when_free(child, attempts) do
    # `restore_child/1` starts the application before reaching here, but these
    # are `on_exit` callbacks: they run after the test body, and by then another
    # file's teardown may have stopped the application again. There is nothing to
    # restore a child under, and exiting here would fail a test that had already
    # passed -- the next file to start the application gets the tree it expects.
    if Process.whereis(AgentDb.Supervisor) do
      case Supervisor.restart_child(AgentDb.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, :running} -> retry_restart(child, attempts)
        {:error, :shutdown} -> retry_restart(child, attempts)
        _other -> :ok
      end
    else
      :ok
    end
  end

  defp retry_restart(child, attempts) do
    Process.sleep(25)
    restart_when_free(child, attempts - 1)
  end

  @doc """
  Stops the background workers, which would claim the very jobs the queue and
  storage assertions inspect.

  A worker already gone is not an error: the test that follows may have stopped
  it itself, and the state these tests need -- no worker -- holds either way.
  """
  def stop_workers do
    for {id, _, _, _} <- worker_children() do
      _ = Supervisor.terminate_child(AgentDb.Supervisor, id)
    end

    # Legacy single-worker IDs (pre-pool). Ignored when absent.
    for worker <- [AgentDb.Workers.Embedding, AgentDb.Workers.Summarization] do
      _ = Supervisor.terminate_child(AgentDb.Supervisor, worker)
    end

    :ok
  end

  defp worker_children(handler \\ nil) do
    case Process.whereis(AgentDb.Supervisor) do
      nil ->
        []

      _pid ->
        for {id, _, _, _} = child <- Supervisor.which_children(AgentDb.Supervisor),
            worker_child?(id, handler) do
          child
        end
    end
  end

  defp worker_child?({handler, _n}, nil)
       when handler in [AgentDb.Workers.Embedding, AgentDb.Workers.Summarization],
       do: true

  defp worker_child?({handler, _n}, handler), do: true
  defp worker_child?(_id, _handler), do: false

  @doc """
  Makes a job claimable again straight away.

  A failed job is rescheduled with backoff, seconds out. Bringing its schedule
  forward is what waiting would have done, and keeps the retry assertions about
  retry rather than about sleeping.
  """
  def make_runnable(job_id) do
    AgentDb.Store.Writer.call(fn conn ->
      AgentDb.Store.SQLite.exec_write(
        conn,
        "UPDATE job_queue SET scheduled_at = ?1 WHERE id = ?2",
        [System.system_time(:millisecond), job_id]
      )
    end)
  end
end

defmodule AgentDb.StorageContract do
  @moduledoc """
  What every storage provider has to do, expressed once.

  A provider that satisfies this suite can be selected at startup in place of
  the default and the store keeps the guarantees the rest of the system relies
  on: a write is durable, a removal is complete and atomic, and work that was
  already in flight cannot bring a removed URI back.

  The suite drives the port directly rather than the public facade, because the
  facade's behaviour is verified separately and a provider is only responsible
  for its own half of it.
  """
  use ExUnit.CaseTemplate

  @callback storage() :: module()

  @doc """
  Breaks the provider's durable state so that a write fails part way through,
  and returns a function that puts it back.

  The rollback guarantees cannot be observed without a write that fails after it
  has already done something, and only a provider can arrange that: this is where
  a store drops a table, a collection loses its connection, or whatever serving
  it stands in for is taken away.
  """
  @callback break_writes() :: (-> :ok)

  using do
    quote do
      @behaviour AgentDb.StorageContract

      import AgentDb.StorageContract, only: [storage_contract: 0]
      import AgentDb.StorageContract.Helpers
    end
  end

  setup do
    alias AgentDb.StorageContract.Helpers

    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Application.put_env(:agent_db, :storage_adapter, AgentDb.Adapters.SQLite)
    :ok = Helpers.restart_app()
    :ok = Helpers.stop_workers()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :storage_adapter)
    end)

    :ok
  end

  @doc "The expectations every provider is measured against."
  defmacro storage_contract do
    quote do
      describe "documents" do
        test "a written document reads back identically" do
          uri = "viking://resources/contract/a.md"

          assert :ok = storage().put_document(uri, "the body", [])

          assert {:ok, node} = storage().get_node(uri)
          assert node.content == "the body"
          assert node.kind == :doc
          assert node.uri == uri
        end

        test "missing parents are created implicitly" do
          assert :ok = storage().put_document("viking://resources/contract/deep/a/b.md", "x", [])

          assert {:ok, node} = storage().get_node("viking://resources/contract/deep/a")
          assert node.kind == :dir
        end

        test "a URI holding nothing is reported as absent, not as a failure" do
          assert {:ok, nil} = storage().get_node("viking://resources/contract/nothing.md")
        end

        test "a caller-supplied layer is stored and an unsupplied one is left alone" do
          uri = "viking://resources/contract/layers.md"
          assert :ok = storage().put_document(uri, "body", abstract: "L0", overview: nil)

          assert {:ok, node} = storage().get_node(uri)
          assert node.abstract == "L0"
          assert node.overview == nil

          # A re-write that carries no summary must not discard the one it did.
          assert :ok = storage().put_document(uri, "new body", [])
          assert {:ok, node} = storage().get_node(uri)
          assert node.abstract == "L0"
          assert node.content == "new body"
        end

        test "children are listed directly and a missing URI is not" do
          assert :ok = storage().put_document("viking://resources/contract/tree/a.md", "a", [])

          assert :ok =
                   storage().put_document("viking://resources/contract/tree/nested/b.md", "b", [])

          assert {:ok, ["a.md", "nested"]} =
                   storage().list_children("viking://resources/contract/tree")

          assert {:error, :not_found} =
                   storage().list_children("viking://resources/contract/absent")
        end

        test "a document is not a directory to list" do
          uri = "viking://resources/contract/leaf.md"
          assert :ok = storage().put_document(uri, "a", [])

          assert {:error, :not_found} = storage().list_children(uri)
        end
      end

      describe "removal" do
        test "removes a subtree from every store keyed by URI" do
          parent = "viking://resources/contract/gone"
          child = parent <> "/deep/a.md"
          outside = "viking://resources/contract/kept.md"

          assert {:ok, session_id} = storage().create_session()

          assert :ok = storage().put_document(parent <> "/deep/b.md", "b", [])
          assert :ok = storage().put_document(child, "a", [])
          assert :ok = storage().put_document(outside, "kept", [])
          assert {:ok, _} = storage().enqueue_job(:embed, %{uri: child, content: "a"})
          assert {:ok, _} = storage().enqueue_job(:embed, %{uri: outside, content: "kept"})
          assert :ok = storage().put_commit(session_id, child, "hash", "committed")
          assert :ok = storage().put_memory(parent <> "/mem", "a fact", 0.5, nil)

          assert :ok = storage().remove_subtree(parent)

          assert {:ok, nil} = storage().get_node(child)
          assert {:ok, nil} = storage().get_node(parent)
          # Nothing outside the subtree moved, including its queued work.
          assert {:ok, node} = storage().get_node(outside)
          assert node.content == "kept"
          assert 1 = storage().count_jobs(outside, ["pending", "running", "done", "failed"])
          assert 0 = storage().count_jobs(child, ["pending", "running", "done", "failed"])
          # Commit bookkeeping for the removed destination is gone, so a later
          # commit of the same session restores the document rather than
          # reporting it unchanged.
          assert {:ok, nil} = storage().commit_hash(session_id, child)
          assert {:ok, []} = storage().recall_memories(parent, nil, [:active, :superseded])
        end

        test "a rejected removal leaves everything untouched" do
          uri = "viking://resources/contract/present.md"
          assert :ok = storage().put_document(uri, "kept", [])

          assert {:error, :not_found} =
                   storage().remove_subtree("viking://resources/contract/absent")

          assert {:ok, node} = storage().get_node(uri)
          assert node.content == "kept"
        end

        test "the tree root is not removable" do
          assert {:error, :is_root} = storage().remove_subtree("viking://")

          assert :ok =
                   storage().put_document("viking://resources/after-root.md", "still here", [])
        end

        test "a URI that is not a viking URI is rejected" do
          assert {:error, :invalid_uri} = storage().remove_subtree("http://elsewhere/x")
        end
      end

      describe "replacing a subtree" do
        test "each file is stored at the path it was given, with work queued for it" do
          uri = "viking://user/alice/skills/imported"

          assert {:ok, %{replaced: false, files: 2}} =
                   storage().replace_skill(uri, [
                     %{path: ["SKILL.md"], content: "the manifest"},
                     %{path: ["references", "guide.md"], content: "the guide"}
                   ])

          assert {:ok, node} = storage().get_node(uri <> "/SKILL.md")
          assert node.content == "the manifest"
          assert {:ok, nested} = storage().get_node(uri <> "/references/guide.md")
          assert nested.content == "the guide"
          # A directory above them exists, and a file is queued for the work a
          # write would have queued, so it is searchable on the same terms.
          assert {:ok, dir} = storage().get_node(uri <> "/references")
          assert dir.kind == :dir
          assert storage().count_jobs(uri <> "/SKILL.md", ["pending", "running"]) > 0
        end

        test "what was there before is gone, from every store keyed by URI" do
          uri = "viking://user/alice/skills/replaced"
          outside = "viking://user/alice/skills/kept/SKILL.md"

          assert :ok = storage().put_document(uri <> "/stale.md", "stale", [])
          assert :ok = storage().put_document(uri <> "/deep/stale.md", "stale", [])
          assert :ok = storage().put_memory(uri <> "/fact", "a fact", 0.5, nil)

          assert {:ok, _} =
                   storage().enqueue_job(:embed, %{uri: uri <> "/stale.md", content: "s"})

          assert :ok = storage().put_document(outside, "kept", [])

          assert {:ok, %{replaced: true}} =
                   storage().replace_skill(uri, [%{path: ["SKILL.md"], content: "the manifest"}])

          assert {:ok, nil} = storage().get_node(uri <> "/stale.md")
          assert {:ok, nil} = storage().get_node(uri <> "/deep/stale.md")
          assert {:ok, []} = storage().recall_memories(uri, nil, [:active, :superseded])
          assert 0 = storage().count_jobs(uri, ["pending", "running", "done", "failed"])
          # Nothing outside the replaced subtree moved.
          assert {:ok, node} = storage().get_node(outside)
          assert node.content == "kept"
        end

        test "a failed replacement leaves the previous subtree intact" do
          uri = "viking://user/alice/skills/rolled-back"
          assert :ok = storage().put_document(uri <> "/SKILL.md", "the old manifest", [])
          assert :ok = storage().put_document(uri <> "/old.md", "the old file", [])
          assert {:ok, _} = storage().enqueue_job(:embed, %{uri: uri <> "/old.md", content: "o"})

          # A store that is not there makes a step of the replacement fail, after
          # the removal has already run. Without a transaction the removal is
          # committed by then, and the URI is left holding nothing at all.
          restore = break_writes()

          try do
            assert {:error, _reason} =
                     storage().replace_skill(uri, [
                       %{path: ["SKILL.md"], content: "the new manifest"},
                       %{path: ["new.md"], content: "the new file"}
                     ])
          after
            restore.()
          end

          assert {:ok, node} = storage().get_node(uri <> "/SKILL.md")
          assert node.content == "the old manifest"
          assert {:ok, kept} = storage().get_node(uri <> "/old.md")
          assert kept.content == "the old file"
          assert {:ok, nil} = storage().get_node(uri <> "/new.md")
          # The work queued for the old subtree is still queued for it.
          assert storage().count_jobs(uri <> "/old.md", ["pending", "running", "done", "failed"]) ==
                   1
        end

        test "a URI that is not a viking URI is rejected" do
          assert {:error, :invalid_uri} = storage().replace_skill("http://elsewhere/x", [])
        end
      end

      describe "results of work that was already in flight" do
        test "a removed node is not given an embedding" do
          uri = "viking://resources/contract/vanished.md"
          assert :ok = storage().put_document(uri, "body", [])
          assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "body"})
          assert {:ok, _job} = storage().dequeue_job([:embed])

          assert :ok = storage().remove_subtree(uri)

          # The job was claimed before the removal, so cancelling queued work
          # could not have caught it. The write is fenced on the node instead.
          assert {:ok, :discarded} =
                   storage().put_embedding_result(
                     job_id,
                     uri,
                     :binary.copy(<<0.0::float-32>>, 384)
                   )

          assert {:ok, []} = storage().search_keyword("body", nil, 10)
        end

        test "a removed node is not given a summary" do
          uri = "viking://resources/contract/vanished-2.md"
          assert :ok = storage().put_document(uri, "body", [])

          assert {:ok, job_id} =
                   storage().enqueue_job(:summarize_abstract, %{uri: uri, content: "body"})

          assert {:ok, _job} = storage().dequeue_job([:summarize_abstract])

          assert :ok = storage().remove_subtree(uri)

          assert {:ok, :discarded} =
                   storage().put_layer_result(job_id, uri, :abstract, "too late")

          assert {:ok, nil} = storage().get_node(uri)
        end

        test "a node that is still there is given the result, and the job is done" do
          uri = "viking://resources/contract/still-here.md"
          assert :ok = storage().put_document(uri, "body", [])

          assert {:ok, job_id} =
                   storage().enqueue_job(:summarize_abstract, %{uri: uri, content: "body"})

          assert {:ok, _job} = storage().dequeue_job([:summarize_abstract])

          assert {:ok, :stored} = storage().put_layer_result(job_id, uri, :abstract, "one line")

          assert {:ok, node} = storage().get_node(uri)
          assert node.abstract == "one line"
          assert {:error, :empty} = storage().dequeue_job([:summarize_abstract])
        end
      end

      describe "search" do
        test "matches a substring regardless of case" do
          assert :ok =
                   storage().put_document(
                     "viking://resources/contract/search/one.md",
                     "QuicK",
                     []
                   )

          assert {:ok, [hit]} = storage().search_keyword("quick", nil, 10)
          assert hit.uri == "viking://resources/contract/search/one.md"
        end

        test "a scope limits the result to one subtree" do
          scope = "viking://resources/contract/scoped"
          assert :ok = storage().put_document(scope <> "/in.md", "needlehere", [])

          assert :ok =
                   storage().put_document("viking://resources/contract/out.md", "needlehere", [])

          assert {:ok, [hit]} = storage().search_keyword("needlehere", scope <> "/", 10)
          assert hit.uri == scope <> "/in.md"
        end

        test "a keyword search is bounded and ordered" do
          scope = "viking://resources/contract/bounded"

          for n <- 1..5 do
            assert :ok = storage().put_document("#{scope}/doc#{n}.md", "sharedterm", [])
          end

          assert {:ok, bounded} = storage().search_keyword("sharedterm", scope <> "/", 3)
          assert length(bounded) == 3

          # Ordered by URI, so the same query returns the same documents however
          # many times it is asked.
          uris = Enum.map(bounded, & &1.uri)
          assert uris == Enum.sort(uris)

          assert {:ok, again} = storage().search_keyword("sharedterm", scope <> "/", 3)
          assert Enum.map(again, & &1.uri) == uris
        end
      end

      describe "find_paths" do
        test "finds paths by name within a subtree, ordered, without content" do
          scope = "viking://resources/contract/find"
          assert :ok = storage().put_document(scope <> "/auth-service.md", "a", [])
          assert :ok = storage().put_document(scope <> "/nested/auth-helper.md", "b", [])

          assert :ok =
                   storage().put_document(
                     "viking://resources/contract/other/auth-outside.md",
                     "c",
                     []
                   )

          assert {:ok, hits} = storage().find_paths("auth", scope, 50)

          assert Enum.map(hits, & &1.uri) == [
                   scope <> "/auth-service.md",
                   scope <> "/nested/auth-helper.md"
                 ]

          for hit <- hits do
            assert %{uri: _, name: _, kind: _} = hit
            refute Map.has_key?(hit, :content)
          end

          assert hd(hits).name == "auth-service.md"
        end

        test "scope is exact-URI-or-descendant, not a raw prefix" do
          scope = "viking://resources/contract/project"
          assert :ok = storage().put_document(scope <> "/auth.md", "in", [])

          assert :ok =
                   storage().put_document(
                     "viking://resources/contract/project-old/auth.md",
                     "sibling",
                     []
                   )

          assert {:ok, hits} = storage().find_paths("auth", scope, 50)
          assert Enum.map(hits, & &1.uri) == [scope <> "/auth.md"]
        end

        test "includes the scope node itself when it matches" do
          scope = "viking://resources/contract/scope-self-auth"
          assert :ok = storage().put_document(scope, "self doc", [])
          assert :ok = storage().put_document(scope <> "/child.md", "child", [])

          assert {:ok, hits} = storage().find_paths("self-auth", scope, 50)
          assert scope in Enum.map(hits, & &1.uri)
        end

        test "treats %, _, and backslash literally" do
          base = "viking://resources/contract/literal"
          assert :ok = storage().put_document(base <> "/100%.md", "a", [])
          assert :ok = storage().put_document(base <> "/a_b.md", "b", [])
          assert :ok = storage().put_document(base <> "/normal.md", "c", [])

          assert {:ok, percent} = storage().find_paths("%", nil, 50)
          assert Enum.map(percent, & &1.uri) == [base <> "/100%.md"]

          assert {:ok, underscore} = storage().find_paths("_", nil, 50)
          # Only URIs containing a literal underscore match; unescaped `_`
          # would match every URI as a single-character wildcard.
          assert Enum.map(underscore, & &1.uri) == [base <> "/a_b.md"]

          assert {:ok, []} = storage().find_paths("\\", nil, 50)
        end

        test "returns nothing when nothing matches and respects the limit" do
          base = "viking://resources/contract/find-limit"
          assert :ok = storage().put_document(base <> "/c.md", "x", [])
          assert :ok = storage().put_document(base <> "/b.md", "x", [])
          assert :ok = storage().put_document(base <> "/a.md", "x", [])

          assert {:ok, []} = storage().find_paths("no-such-name", nil, 50)

          assert {:ok, hits} = storage().find_paths(".md", nil, 2)
          assert length(hits) == 2
          assert Enum.map(hits, & &1.uri) == Enum.sort(Enum.map(hits, & &1.uri))
        end
      end

      describe "grep_content" do
        test "returns matching lines with numbers and bounded excerpts, ordered" do
          uri = "viking://resources/contract/grep/a.md"
          content = "first line\nsecond AUTH line\nthird line\nAUTH again line 4"
          assert :ok = storage().put_document(uri, content, [])

          assert {:ok, hits} = storage().grep_content("auth", nil, 50)
          assert [%{uri: ^uri, line_number: 2}, %{uri: ^uri, line_number: 4}] = hits

          for hit <- hits do
            assert String.contains?(String.downcase(hit.excerpt), "auth")
            assert String.length(hit.excerpt) <= 280
          end
        end

        test "scopes to the scope node and its descendants only" do
          scope = "viking://resources/contract/grep-scope"
          assert :ok = storage().put_document(scope <> "/in.md", "needlegrep here", [])

          assert :ok =
                   storage().put_document(
                     "viking://resources/contract/grep-out.md",
                     "needlegrep here",
                     []
                   )

          assert :ok =
                   storage().put_document(
                     "viking://resources/contract/grep-scope-old/in.md",
                     "needlegrep here",
                     []
                   )

          assert {:ok, hits} = storage().grep_content("needlegrep", scope, 50)
          assert Enum.map(hits, & &1.uri) == [scope <> "/in.md"]
        end

        test "matches L2 content only, never abstracts or overviews" do
          uri = "viking://resources/contract/grep-layers.md"

          assert :ok =
                   storage().put_document(uri, "plain body",
                     abstract: "unique-abstract-term",
                     overview: "unique-overview-term"
                   )

          assert {:ok, []} = storage().grep_content("unique-abstract-term", nil, 50)
          assert {:ok, []} = storage().grep_content("unique-overview-term", nil, 50)
          assert {:ok, [_]} = storage().grep_content("plain body", nil, 50)
        end

        test "treats special characters literally" do
          uri = "viking://resources/contract/grep-special.md"

          assert :ok =
                   storage().put_document(
                     uri,
                     "100% sure\na_b\nprice [test] ok\na.*b literal\nback\\slash here",
                     []
                   )

          assert {:ok, [_]} = storage().grep_content("%", nil, 50)
          assert {:ok, [_]} = storage().grep_content("_", nil, 50)
          assert {:ok, [_]} = storage().grep_content("[test]", nil, 50)
          assert {:ok, [_]} = storage().grep_content(".*", nil, 50)
          assert {:ok, [_]} = storage().grep_content("\\", nil, 50)
          assert {:ok, []} = storage().grep_content("no-such-grep-term", nil, 50)
        end

        test "bounds long lines and respects the limit" do
          uri = "viking://resources/contract/grep-long.md"
          long = String.duplicate("x", 200) <> "needle" <> String.duplicate("y", 300)
          assert :ok = storage().put_document(uri, long, [])

          assert {:ok, [hit]} = storage().grep_content("needle", nil, 50)
          assert hit.uri == uri
          assert hit.line_number == 1
          assert String.contains?(hit.excerpt, "needle")
          assert String.length(hit.excerpt) <= 280

          many = Enum.map_join(1..5, "\n", fn _ -> "hitline needle" end)

          assert :ok =
                   storage().put_document("viking://resources/contract/grep-many.md", many, [])

          assert {:ok, hits} = storage().grep_content("needle", nil, 2)
          assert length(hits) == 2
          uris = Enum.map(hits, & &1.uri)
          assert uris == Enum.sort(uris)
        end
      end

      describe "sessions" do
        test "messages are kept in order" do
          assert {:ok, session_id} = storage().create_session()

          assert :ok = storage().append_message(session_id, :user, "first")
          assert :ok = storage().append_message(session_id, :assistant, "second")

          assert {:ok, messages} = storage().get_session(session_id)
          assert Enum.map(messages, & &1.content) == ["first", "second"]
          assert Enum.map(messages, & &1.role) == [:user, :assistant]
        end

        test "a commit records its hash with the document it wrote" do
          destination = "viking://resources/contract/committed"
          assert {:ok, first} = storage().create_session()
          assert {:ok, second} = storage().create_session()

          assert {:ok, nil} = storage().commit_hash(first, destination)
          assert :ok = storage().put_commit(first, destination, "hash-1", "the transcript")

          assert {:ok, "hash-1"} = storage().commit_hash(first, destination)
          assert {:ok, node} = storage().get_node(destination)
          assert node.content == "the transcript"

          # A second session's commit to the same destination is separate.
          assert {:ok, nil} = storage().commit_hash(second, destination)
        end
      end

      describe "memories" do
        test "a revised memory keeps exactly one active assertion" do
          uri = "viking://user/memories/preferences/language"

          assert :ok = storage().put_memory(uri, "uses Go", 0.6, "s1")
          assert :ok = storage().put_memory(uri, "uses Elixir", 0.9, "s2")

          assert {:ok, [active]} = storage().recall_memories(uri, nil, [:active])
          assert active.value == "uses Elixir"
          assert active.confidence == 0.9
          assert active.source == "s2"

          assert {:ok, history} = storage().recall_memories(uri, nil, [:active, :superseded])
          assert length(history) == 2
          assert Enum.count(history, &(&1.status == :active)) == 1
        end

        test "a subtree is recalled most confident first" do
          assert :ok = storage().put_memory("viking://user/memories/events/low", "low", 0.2, nil)

          assert :ok =
                   storage().put_memory("viking://user/memories/events/high", "high", 0.9, nil)

          assert {:ok, found} =
                   storage().recall_memories("viking://user/memories/events", nil, [:active])

          assert Enum.map(found, & &1.confidence) == [0.9, 0.2]
        end

        test "a term restricts a recall" do
          assert :ok =
                   storage().put_memory(
                     "viking://user/memories/entities/one",
                     "kubernetes",
                     0.5,
                     nil
                   )

          assert :ok =
                   storage().put_memory(
                     "viking://user/memories/entities/two",
                     "postgres",
                     0.5,
                     nil
                   )

          assert {:ok, [hit]} =
                   storage().recall_memories("viking://user/memories/entities", "KUBERNETES", [
                     :active
                   ])

          assert hit.value == "kubernetes"
        end

        test "a URI is asked about whether it holds a memory at all" do
          uri = "viking://user/memories/profile/name"
          assert :ok = storage().put_memory(uri, "ada", 0.5, nil)

          assert {:ok, true} = storage().memory_recorded?(uri)

          assert {:ok, false} =
                   storage().memory_recorded?("viking://user/memories/profile/nobody")
        end
      end

      describe "durable work" do
        test "a claimed job leaves the queue and records its attempt" do
          uri = "viking://resources/contract/j.md"
          assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

          assert {:ok, job} = storage().dequeue_job([:embed])
          assert job.id == job_id
          assert job.kind == :embed
          assert job.payload["uri"] == uri
          assert job.attempts == 1
          assert {:error, :empty} = storage().dequeue_job([:embed])
        end

        test "a worker is handed only the kinds it can run" do
          assert {:ok, _} =
                   storage().enqueue_job(:summarize_abstract, %{
                     uri: "viking://resources/contract/s.md",
                     content: "c"
                   })

          # Claiming for a kind that has no work must not consume work of
          # another kind: a claimed job cannot be handed back.
          assert {:error, :empty} = storage().dequeue_job([:embed])

          assert {:ok, job} = storage().dequeue_job([:summarize_abstract])
          assert job.kind == :summarize_abstract
        end

        test "a job is counted by URI and by status" do
          uri = "viking://resources/contract/counted.md"
          assert {:ok, _id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})
          assert 1 = storage().count_jobs(uri, ["pending", "running"])
          assert 0 = storage().count_jobs(uri, ["failed"])

          assert {:ok, _job} = storage().dequeue_job([:embed])
          assert 1 = storage().count_jobs(uri, ["running"])
        end

        test "completing a job takes it out of the queue" do
          uri = "viking://resources/contract/done.md"
          assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})
          assert {:ok, _job} = storage().dequeue_job([:embed])

          assert :ok = storage().complete_job(job_id)
          assert 0 = storage().count_jobs(uri, ["pending", "running"])
        end

        test "a failure is retried while attempts remain, then given up on" do
          uri = "viking://resources/contract/failing.md"
          assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

          for _attempt <- 1..5 do
            assert {:ok, _job} = storage().dequeue_job([:embed])
            assert :ok = storage().fail_job(job_id)
            make_runnable(job_id)
          end

          assert 0 = storage().count_jobs(uri, ["pending", "running"])
          assert 1 = storage().count_jobs(uri, ["failed"])
        end

        test "a deferral does not spend an attempt" do
          uri = "viking://resources/contract/deferred.md"
          assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

          for _round <- 1..3 do
            assert {:ok, _job} = storage().dequeue_job([:embed])
            assert :ok = storage().defer_job(job_id, 0)
          end

          # Still claimable, and its budget untouched: a job merely waiting for a
          # model has not failed.
          assert {:ok, job} = storage().dequeue_job([:embed])
          assert job.attempts == 1
          assert 0 = storage().count_jobs(uri, ["failed"])
        end

        test "queued work is cancelled for a URI and its descendants only" do
          target = "viking://resources/contract/cancelled"
          other = "viking://resources/contract/other.md"
          assert {:ok, _} = storage().enqueue_job(:embed, %{uri: target, content: "c"})

          assert {:ok, _} =
                   storage().enqueue_job(:embed, %{uri: target <> "/deep.md", content: "c"})

          assert {:ok, _} = storage().enqueue_job(:embed, %{uri: other, content: "see #{target}"})

          assert :ok = storage().cancel_jobs(target)

          all = ["pending", "running", "done", "failed"]
          assert 0 = storage().count_jobs(target, all)
          # A bystander job survives even though its content mentions the URI.
          assert 1 = storage().count_jobs(other, all)
        end

        test "work left running is recovered after a restart" do
          uri = "viking://resources/contract/recovered.md"
          assert {:ok, _id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})
          assert {:ok, _job} = storage().dequeue_job([:embed])

          :ok = restart_app()
          :ok = stop_workers()

          assert {:ok, job} = storage().dequeue_job([:embed])
          assert job.attempts == 1
        end

        test "queued work is reported by status" do
          uri = "viking://resources/contract/stats.md"
          assert {:ok, _id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

          assert {:ok, stats} = storage().queue_stats()
          assert stats.pending >= 1
        end

        test "queue detail reports how far behind the queue is" do
          assert {:ok, %{oldest_pending_ms: age, failed: []}} = storage().queue_detail(10)
          assert is_nil(age) or is_integer(age)
        end

        test "queue detail explains a job that gave up" do
          uri = "viking://resources/contract/gave-up.md"
          assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

          for _attempt <- 1..5 do
            assert {:ok, _job} = storage().dequeue_job([:embed])
            assert :ok = storage().fail_job(job_id, "inference_failed")
            make_runnable(job_id)
          end

          assert {:ok, %{failed: [failed | _]}} = storage().queue_detail(10)
          assert failed.kind == "embed"
          assert failed.uri == uri
          assert failed.attempts == failed.max_attempts
          # The reason is the bounded code, not the failure term: what went
          # wrong has to survive without carrying what it went wrong about.
          assert failed.last_error == "inference_failed"
        end
      end

      describe "composition and footprint" do
        test "counts the documents and directories it holds" do
          assert :ok =
                   storage().put_document("viking://resources/contract/nodes/a.md", "a", jobs: [])

          assert :ok =
                   storage().put_document("viking://resources/contract/nodes/b.md", "b", jobs: [])

          assert {:ok, stats} = storage().stats()
          assert stats.documents >= 2
          assert stats.directories >= 1
        end

        test "counts documents per top-level subtree" do
          assert :ok =
                   storage().put_document("viking://resources/contract/subtree/a.md", "a",
                     jobs: []
                   )

          assert {:ok, stats} = storage().stats()
          assert is_integer(stats.by_top_subtree["resources"])
          assert stats.by_top_subtree["resources"] >= 1
        end

        test "distinguishes an unavailable index from an empty one" do
          assert {:ok, vector} = storage().vector_index_stats()
          assert is_boolean(vector.available)

          # Not available is `nil` counts, never zero: "there is no index" and
          # "the index holds nothing" are different facts.
          if vector.available do
            assert is_integer(vector.vectors)
          else
            assert is_nil(vector.vectors)
          end

          assert is_integer(vector.documents)
        end
      end

      describe "reachability" do
        test "reports a store it can query" do
          assert storage().healthy?() == true
        end
      end
    end
  end
end
