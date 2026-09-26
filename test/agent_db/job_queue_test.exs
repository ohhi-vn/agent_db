defmodule AgentDb.JobQueueTest do
  use ExUnit.Case, async: false

  alias AgentDb.JobQueue
  alias AgentDb.Store.SQLite
  alias AgentDb.Config

  # Generate unique URI per test run to avoid conflicts
  defp unique_uri(base) do
    "viking://test/#{base}/#{:erlang.unique_integer([:positive])}"
  end

  # Read the queue through the writer's connection. Opening a second
  # connection works but hides the bug this file used to have: it inspected
  # Config.data_dir(), which is not necessarily the file the app is running
  # against, so rows written by JobQueue were invisible to these assertions.
  defp query_job_queue(sql, args) do
    AgentDb.Store.Reader.read(fn conn -> SQLite.query_one(conn, sql, args) end)
  end

  defp cancel_for_uri(uri) do
    AgentDb.Store.Writer.call(fn conn -> JobQueue.cancel_for_uri(conn, uri) end)
  end

  defp remaining_job_uris do
    {:ok, set} =
      AgentDb.Store.Reader.read(fn conn ->
        SQLite.query(conn, "SELECT json_extract(payload, '$.uri') FROM job_queue")
      end)

    MapSet.new(set, &hd/1)
  end

  defp update_job_queue(sql, args) do
    AgentDb.Store.Writer.call(fn conn -> SQLite.exec_write(conn, sql, args) end)
  end

  # Clean job queue through the writer connection, and reset auto-increment.
  defp clean_job_queue do
    update_job_queue("DELETE FROM job_queue", [])
    update_job_queue("DELETE FROM sqlite_sequence WHERE name = 'job_queue'", [])
  end

  setup do
    # The queue lives in the running app's database, so point the app at a
    # private directory and restart it. Without this the app keeps whatever
    # data_dir a previously-run test file left behind, and this file's direct
    # SQL assertions read a different file than the one JobQueue writes to.
    Application.put_env(:agent_db, :data_dir, Config.test_data_dir())
    restart_app()
    clean_job_queue()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  describe "enqueue/2 and dequeue/1" do
    test "enqueues and dequeues a job" do
      uri = unique_uri("doc")
      assert {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: uri, content: "hello"})
      assert is_integer(job_id)

      assert {:ok, job} = JobQueue.dequeue("test_worker")
      assert job.id == job_id
      assert job.kind == :embed
      assert job.payload["uri"] == uri
      assert job.payload["content"] == "hello"
      assert job.attempts == 1
    end

    test "returns :empty when no jobs pending" do
      clean_job_queue()
      assert {:error, :empty} = JobQueue.dequeue("test_worker")
    end
  end

  describe "complete/1" do
    test "marks job as done" do
      uri = unique_uri("doc")
      {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: uri, content: "test"})
      {:ok, job} = JobQueue.dequeue("test_worker")

      assert :ok = JobQueue.complete(job_id)

      # Job should not be dequeued again
      assert {:error, :empty} = JobQueue.dequeue("test_worker")
    end
  end

  describe "fail/2 with exponential backoff" do
    test "retries job with backoff on failure" do
      uri = unique_uri("doc")
      {:ok, job_id} = JobQueue.enqueue(:summarize_abstract, %{uri: uri, content: "test"})
      {:ok, job} = JobQueue.dequeue("test_worker")

      # First failure - should reschedule with backoff
      assert :ok = JobQueue.fail(job_id, :timeout)
    end

    test "marks job failed after max attempts" do
      uri = unique_uri("doc")
      {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: uri, content: "test"})

      # Fail it 5 times (max_attempts = 5 by default) by directly updating the database
      # to avoid scheduling delays
      for i <- 1..5 do
        # Dequeue the job
        {:ok, _job} = JobQueue.dequeue("test_worker")
        # Fail it
        assert :ok = JobQueue.fail(job_id, :error)

        # For the next iteration, we need to reset scheduled_at to now
        # so the job is immediately available for dequeue again
        if i < 5 do
          update_job_queue(
            "UPDATE job_queue SET scheduled_at = ?1 WHERE id = ?2",
            [System.system_time(:millisecond), job_id]
          )
        end
      end

      # Verify job is marked as failed
      assert {:ok, ["failed"]} =
               query_job_queue("SELECT status FROM job_queue WHERE id = ?1", [job_id])
    end
  end

  describe "reset_running_jobs/0" do
    test "resets running jobs to pending on startup" do
      uri = unique_uri("doc")
      {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: uri, content: "test"})
      {:ok, _job} = JobQueue.dequeue("test_worker")

      # Verify job is now running
      assert {:ok, ["running", 1]} =
               query_job_queue("SELECT status, attempts FROM job_queue WHERE id = ?1", [job_id])

      # Simulate crash/restart - job is still "running"
      # reset_running_jobs should make it pending again
      assert :ok = JobQueue.reset_running_jobs()

      # Verify job was reset
      assert {:ok, ["pending", 0]} =
               query_job_queue("SELECT status, attempts FROM job_queue WHERE id = ?1", [job_id])

      # Now it should be available for dequeue again
      {:ok, job2} = JobQueue.dequeue("test_worker2")
      assert job2.id == job_id
      assert job2.attempts == 1
    end
  end

  describe "cancel_for_uri/2" do
    test "removes jobs for the exact URI and for descendants" do
      exact = unique_uri("sub")
      child = exact <> "/child.md"
      grandchild = exact <> "/deep/leaf.md"
      other = unique_uri("other")

      for uri <- [exact, child, grandchild, other] do
        {:ok, _} = JobQueue.enqueue(:embed, %{uri: uri, content: "c"})
      end

      assert :ok = cancel_for_uri(exact)

      assert remaining_job_uris() == MapSet.new([other])
    end

    test "removes running jobs, not just pending ones" do
      uri = unique_uri("sub")
      {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: uri, content: "c"})
      {:ok, _job} = JobQueue.dequeue("test_worker")

      assert {:ok, ["running"]} =
               query_job_queue("SELECT status FROM job_queue WHERE id = ?1", [job_id])

      assert :ok = cancel_for_uri(uri)
      assert remaining_job_uris() == MapSet.new()
    end

    test "leaves a job whose content mentions the URI but targets another one" do
      target = unique_uri("sub")
      bystander = unique_uri("other")

      {:ok, _} =
        JobQueue.enqueue(:embed, %{uri: bystander, content: "see #{target} for details"})

      assert :ok = cancel_for_uri(target)
      assert remaining_job_uris() == MapSet.new([bystander])
    end

    test "a cancelled job cannot be dequeued" do
      uri = unique_uri("sub")
      {:ok, _} = JobQueue.enqueue(:embed, %{uri: uri, content: "c"})

      assert :ok = cancel_for_uri(uri)
      assert {:error, :empty} = JobQueue.dequeue("test_worker")
    end
  end

  describe "stats/0" do
    test "returns queue statistics" do
      JobQueue.enqueue(:embed, %{uri: unique_uri("doc1"), content: "test1"})
      JobQueue.enqueue(:summarize_abstract, %{uri: unique_uri("doc2"), content: "test2"})

      assert {:ok, stats} = JobQueue.stats()
      assert is_map(stats)
    end
  end
end
