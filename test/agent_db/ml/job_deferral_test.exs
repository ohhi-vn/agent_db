defmodule AgentDb.ML.JobDeferralTest do
  use ExUnit.Case, async: false

  alias AgentDb.JobQueue
  alias AgentDb.Store.SQLite

  setup do
    # The application's own workers dequeue from whichever Writer holds the
    # registered name, and its Reader pool is bound to the application's data
    # dir. Both would race this file's assertions, so the whole application is
    # stopped and a private Writer/Reader pair is started instead.
    :ok = Application.stop(:agent_db)

    path = Path.join(System.tmp_dir!(), "agent_db_defer_#{:erlang.unique_integer([:positive])}")
    {:ok, conn} = SQLite.open(path)
    :ok = SQLite.ensure_schema(conn)
    SQLite.close(conn)

    start_supervised!({AgentDb.Store.Writer, [path: path]})
    start_supervised!({AgentDb.Store.Reader, [path: path, size: 1]})

    on_exit(fn ->
      File.rm_rf(path)
      {:ok, _} = Application.ensure_all_started(:agent_db)
    end)

    :ok
  end

  defp attempts(job_id) do
    AgentDb.Store.Reader.read(fn conn ->
      SQLite.query_one(conn, "SELECT attempts, status FROM job_queue WHERE id = ?1", [job_id])
    end)
  end

  test "defer/2 gives back the attempt dequeue/1 consumed" do
    {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: "viking://a.md", content: "c"})
    {:ok, _job} = JobQueue.dequeue("w")

    # dequeue advanced the attempt counter.
    assert {:ok, [1, "running"]} = attempts(job_id)

    assert :ok = JobQueue.defer(job_id, 0)

    # The deferral is attempt-neutral, so waiting cannot exhaust the budget.
    assert {:ok, [0, "pending"]} = attempts(job_id)
  end

  test "repeated deferrals never mark the job failed" do
    {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: "viking://b.md", content: "c"})

    for _ <- 1..25 do
      {:ok, _job} = JobQueue.dequeue("w")
      assert :ok = JobQueue.defer(job_id, 0)
    end

    assert {:ok, [0, "pending"]} = attempts(job_id)

    # Still eligible, where a failure path would have exhausted 5 attempts.
    assert {:ok, _job} = JobQueue.dequeue("w")
  end

  test "a deferred job is a different state from a failed one" do
    {:ok, deferred} = JobQueue.enqueue(:embed, %{uri: "viking://c.md", content: "c"})
    {:ok, _} = JobQueue.dequeue("w")
    :ok = JobQueue.defer(deferred, 60_000)

    {:ok, failed} = JobQueue.enqueue(:embed, %{uri: "viking://d.md", content: "c"})
    for _ <- 1..5 do
      {:ok, _} = JobQueue.dequeue("w")
      :ok = JobQueue.fail(failed, :boom)
      # Make the job immediately claimable again for the next attempt.
      AgentDb.Store.Writer.call(fn conn ->
        SQLite.exec_write(
          conn,
          "UPDATE job_queue SET scheduled_at = ?1 WHERE id = ?2",
          [System.system_time(:millisecond), failed]
        )
      end)
    end

    assert {:ok, [_deferred_attempts, "pending"]} = attempts(deferred)
    assert {:ok, [_failed_attempts, "failed"]} = attempts(failed)
  end

  test "a deferred job survives a restart" do
    {:ok, job_id} = JobQueue.enqueue(:embed, %{uri: "viking://e.md", content: "c"})
    {:ok, _} = JobQueue.dequeue("w")

    # Defer far enough out that reset_running_jobs cannot be what recovers it.
    :ok = JobQueue.defer(job_id, 60_000)
    assert {:ok, [0, "pending"]} = attempts(job_id)

    # A pending row is recovered by a restart untouched, unlike a running one.
    assert :ok = JobQueue.reset_running_jobs()
    assert {:ok, [0, "pending"]} = attempts(job_id)
  end
end
