defmodule AgentDb.JobQueueTest do
  use ExUnit.Case, async: false

  alias AgentDb.JobQueue
  alias AgentDb.Store.{SQLite}
  alias AgentDb.Config

  # Generate unique URI per test run to avoid conflicts
  defp unique_uri(base) do
    "viking://test/#{base}/#{:erlang.unique_integer([:positive])}"
  end

  # Clean job queue - best effort, also reset auto-increment
  defp clean_job_queue do
    path = Path.join(Config.data_dir(), "agent_db.db")
    case SQLite.open(path) do
      {:ok, conn} ->
        SQLite.exec_write(conn, "DELETE FROM job_queue")
        # Reset auto-increment counter
        SQLite.exec_write(conn, "DELETE FROM sqlite_sequence WHERE name = 'job_queue'")
        SQLite.close(conn)
      {:error, _} ->
        :ok
    end
  end

  setup do
    clean_job_queue()
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
          path = Path.join(Config.data_dir(), "agent_db.db")
          {:ok, conn} = SQLite.open(path)
          SQLite.exec_write(conn, 
            "UPDATE job_queue SET scheduled_at = ?1 WHERE id = ?2",
            [System.system_time(:millisecond), job_id]
          )
          SQLite.close(conn)
        end
      end

      # Verify job is marked as failed by checking database directly
      path = Path.join(Config.data_dir(), "agent_db.db")
      {:ok, conn} = SQLite.open(path)
      assert {:ok, [["failed"]]} = SQLite.query_one(conn, "SELECT status FROM job_queue WHERE id = ?1", [job_id])
      SQLite.close(conn)
    end
  end

  describe "reset_running_jobs/0" do
    test "resets running jobs to pending on startup" do
      uri = unique_uri("doc")
      {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: uri, content: "test"})
      {:ok, job} = JobQueue.dequeue("test_worker")

      # Verify job is now running
      path = Path.join(Config.data_dir(), "agent_db.db")
      {:ok, conn} = SQLite.open(path)
      assert {:ok, [["running", 1]]} = SQLite.query_one(
        conn,
        "SELECT status, attempts FROM job_queue WHERE id = ?1",
        [job_id]
      )
      SQLite.close(conn)

      # Simulate crash/restart - job is still "running"
      # reset_running_jobs should make it pending again
      assert :ok = JobQueue.reset_running_jobs()

      # Verify job was reset by checking database directly
      {:ok, conn} = SQLite.open(path)
      assert {:ok, [["pending", 0]]} = SQLite.query_one(
        conn,
        "SELECT status, attempts FROM job_queue WHERE id = ?1",
        [job_id]
      )
      SQLite.close(conn)

      # Now it should be available for dequeue again
      {:ok, job2} = JobQueue.dequeue("test_worker2")
      assert job2.id == job_id
      assert job2.attempts == 1
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