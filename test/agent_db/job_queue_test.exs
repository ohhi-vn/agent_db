defmodule AgentDb.JobQueueTest do
  @moduledoc """
  The durable queue's own behaviour: claim, retry, defer, recover, cancel.

  The queue is reached through the storage port rather than its SQL, so what
  these assert is the behaviour a caller can rely on, not a table layout. The
  cross-store guarantees that depend on the queue -- removal cancelling work, a
  removed node not regaining a result -- live in the storage contract.
  """
  use ExUnit.Case, async: false

  alias AgentDb.StorageContract.Helpers
  alias AgentDb.Store.SQLite

  setup do
    # The queue lives in the running app's database, so the app needs a private
    # directory: otherwise it keeps whatever a previously-run test file left
    # behind and these assertions read a different file than the one being
    # written to.
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    :ok = Helpers.restart_app()
    :ok = Helpers.stop_workers()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  defp storage, do: AgentDb.Adapters.SQLite

  defp unique_uri(base), do: "viking://test/#{base}/#{:erlang.unique_integer([:positive])}"

  describe "claiming" do
    test "a claimed job leaves the queue and records its attempt" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "hello"})

      assert {:ok, job} = storage().dequeue_job([:embed])
      assert job.id == job_id
      assert job.kind == :embed
      assert job.payload["uri"] == uri
      assert job.payload["content"] == "hello"
      assert job.attempts == 1
    end

    test "an empty queue is reported as empty rather than as a failure" do
      assert {:error, :empty} = storage().dequeue_job([:embed])
    end

    test "a worker is handed only the kinds it can run" do
      uri = unique_uri("doc")
      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

      # Claiming for another kind must leave this one claimable: a claimed job
      # cannot be handed back, so a filter that ignored kinds would destroy it.
      assert {:error, :empty} = storage().dequeue_job([:summarize_abstract])

      assert {:ok, %{kind: :embed}} = storage().dequeue_job([:embed])
    end

    test "a job that is not yet due stays in the queue" do
      uri = unique_uri("doc")
      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

      # Deferred into the future: due time is what makes it runnable.
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})
      {:ok, _} = storage().dequeue_job([:embed])
      assert :ok = storage().defer_job(job_id, 60_000)

      assert {:error, :empty} = storage().dequeue_job([:embed])
    end
  end

  describe "completing" do
    test "a completed job is not claimed again" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "test"})
      assert {:ok, _job} = storage().dequeue_job([:embed])

      assert :ok = storage().complete_job(job_id)
      assert {:error, :empty} = storage().dequeue_job([:embed])
    end
  end

  describe "failing" do
    test "a failure is retried while attempts remain" do
      uri = unique_uri("doc")

      assert {:ok, job_id} =
               storage().enqueue_job(:summarize_abstract, %{uri: uri, content: "test"})

      assert {:ok, _job} = storage().dequeue_job([:summarize_abstract])
      assert :ok = storage().fail_job(job_id)

      # Rescheduled with backoff, so still counted as outstanding rather than
      # given up on.
      assert 1 = storage().count_jobs(uri, ["pending", "running"])
      assert 0 = storage().count_jobs(uri, ["failed"])
    end

    test "a job is given up on once its attempts are exhausted" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "test"})

      for _attempt <- 1..5 do
        assert {:ok, _job} = storage().dequeue_job([:embed])
        assert :ok = storage().fail_job(job_id)
        Helpers.make_runnable(job_id)
      end

      assert 1 = storage().count_jobs(uri, ["failed"])
    end
  end

  describe "deferring" do
    test "a deferral gives back the attempt the claim consumed" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})
      assert {:ok, _job} = storage().dequeue_job([:embed])

      # The claim advanced the attempt counter; a deferral is not a failure and
      # must hand it back, or repeated waiting would exhaust the budget of work
      # that has not had its chance yet.
      assert :ok = storage().defer_job(job_id, 0)

      assert {:ok, job} = storage().dequeue_job([:embed])
      assert job.attempts == 1
    end

    test "a deferred job is a different state from a failed one" do
      deferred_uri = unique_uri("deferred")
      failed_uri = unique_uri("failed")

      assert {:ok, deferred} = storage().enqueue_job(:embed, %{uri: deferred_uri, content: "c"})
      assert {:ok, _} = storage().dequeue_job([:embed])
      assert :ok = storage().defer_job(deferred, 60_000)

      assert {:ok, failed} = storage().enqueue_job(:embed, %{uri: failed_uri, content: "c"})

      for _attempt <- 1..5 do
        assert {:ok, _} = storage().dequeue_job([:embed])
        assert :ok = storage().fail_job(failed)
        Helpers.make_runnable(failed)
      end

      # Both were claimed the same number of times; only one is finished with.
      assert 1 = storage().count_jobs(deferred_uri, ["pending"])
      assert 0 = storage().count_jobs(deferred_uri, ["failed"])
      assert 1 = storage().count_jobs(failed_uri, ["failed"])
    end
  end

  describe "recovering" do
    test "work left running by a previous run returns to pending" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "test"})
      assert {:ok, _job} = storage().dequeue_job([:embed])

      # A process that died mid-job leaves the row running. Recovery returns it
      # to pending with its attempts reset, because the work was never
      # attempted to completion.
      assert :ok = storage().reset_running_jobs()

      assert {:ok, job} = storage().dequeue_job([:embed])
      assert job.id == job_id
      assert job.attempts == 1
    end

    test "a deferred job is left alone by recovery" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})
      assert {:ok, _job} = storage().dequeue_job([:embed])
      assert :ok = storage().defer_job(job_id, 60_000)

      assert :ok = storage().reset_running_jobs()

      # Still pending, still attempt-free: recovery is about abandoned work, and
      # a job deliberately waiting is not abandoned.
      assert 1 = storage().count_jobs(uri, ["pending"])
      assert {:error, :empty} = storage().dequeue_job([:embed])
    end
  end

  describe "cancelling" do
    test "work for a URI and its descendants is dropped, in any state" do
      target = unique_uri("sub")
      other = unique_uri("other")

      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: target, content: "c"})
      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: target <> "/child.md", content: "c"})
      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: other, content: "c"})

      # One of them is claimed first, so cancellation has to reach a running row
      # as well as a pending one.
      assert {:ok, _} = storage().dequeue_job([:embed])
      assert :ok = storage().cancel_jobs(target)

      every = ["pending", "running", "done", "failed"]
      assert 0 = storage().count_jobs(target, every)
      assert 0 = storage().count_jobs(target <> "/child.md", every)
      assert 1 = storage().count_jobs(other, every)
    end

    test "work whose content mentions a URI is left alone" do
      target = unique_uri("sub")
      bystander = unique_uri("other")

      # Matching the payload's URI rather than its text: a substring match would
      # drop work outside the removed subtree.
      assert {:ok, _} =
               storage().enqueue_job(:embed, %{
                 uri: bystander,
                 content: "see #{target} for details"
               })

      assert :ok = storage().cancel_jobs(target)
      assert 1 = storage().count_jobs(bystander, ["pending"])
    end

    test "cancelled work cannot be claimed" do
      uri = unique_uri("sub")
      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: uri, content: "c"})

      assert :ok = storage().cancel_jobs(uri)
      assert {:error, :empty} = storage().dequeue_job([:embed])
    end
  end

  describe "reporting" do
    test "work is reported by status" do
      assert {:ok, _} = storage().enqueue_job(:embed, %{uri: unique_uri("doc1"), content: "t"})

      assert {:ok, _} =
               storage().enqueue_job(:summarize_abstract, %{uri: unique_uri("doc2"), content: "t"})

      assert {:ok, stats} = storage().queue_stats()
      assert is_map(stats)
      assert stats.pending >= 2
    end
  end

  describe "the storage the queue runs on" do
    test "is reachable" do
      assert storage().healthy?()
    end

    test "runs a single writer, so interleaved writes see each other" do
      tasks = for i <- 1..10, do: Task.async(fn -> store_session("s#{i}") end)

      assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == :ok))

      assert {:ok, [[10]]} =
               AgentDb.Store.Reader.read(fn conn ->
                 SQLite.query(conn, "SELECT COUNT(*) FROM sessions WHERE id LIKE 's%'")
               end)
    end
  end

  defp store_session(id) do
    AgentDb.Store.Writer.call(fn conn ->
      SQLite.exec_write(conn, "INSERT INTO sessions (id, created_at) VALUES (?1, ?2)", [id, id])
    end)
  end
end
