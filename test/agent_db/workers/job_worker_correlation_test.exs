defmodule AgentDb.Workers.JobWorkerCorrelationTest do
  @moduledoc """
  A durable job's logs carry the job id and the trace it was enqueued under.

  The worker sets one correlation for the whole job, so every outcome — stored,
  deferred, failed, discarded — logs the same identifiers without each call site
  repeating them.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentDb.Test.Fakes.Storage
  alias AgentDb.Workers.JobWorker

  @trace %{"trace_id" => "trace-corr", "span_id" => "span-corr"}

  defmodule StoredHandler do
    @behaviour JobWorker.Handler
    def kinds, do: [:embed]
    def generate(_job), do: {:ok, "result"}
    def store(_job, _result), do: {:ok, :stored}
  end

  defmodule DeferredHandler do
    @behaviour JobWorker.Handler
    def kinds, do: [:embed]
    def generate(_job), do: {:error, :model_loading}
    def store(_job, _result), do: {:ok, :stored}
  end

  defmodule FailedHandler do
    @behaviour JobWorker.Handler
    def kinds, do: [:embed]
    def generate(_job), do: {:error, :boom}
    def store(_job, _result), do: {:ok, :stored}
  end

  defmodule DiscardedHandler do
    @behaviour JobWorker.Handler
    def kinds, do: [:embed]
    def generate(_job), do: {:ok, "result"}
    def store(_job, _result), do: {:ok, :discarded}
  end

  setup do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Application.put_env(:agent_db, :storage_adapter, Storage)
    :ok = AgentDb.StorageContract.Helpers.restart_app()
    :ok = AgentDb.StorageContract.Helpers.stop_workers()
    Storage.reset()

    level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: level)
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :storage_adapter)
      AgentDb.Test.Script.clear(:fake_storage)
      :ok = AgentDb.StorageContract.Helpers.restart_app()
    end)

    :ok
  end

  test "a stored job's log carries its job id and trace id" do
    {log, job_id} = run(StoredHandler)

    assert log =~ "trace-corr"
    assert log =~ "job_id"
    assert log =~ "stored"
    assert is_integer(job_id)
  end

  test "a deferred job's log carries its job id and trace id" do
    {log, _job_id} = run(DeferredHandler)

    assert log =~ "trace-corr"
    assert log =~ "job_id"
    assert log =~ "deferred"
  end

  test "a failed job's log carries its job id, trace id, and classified reason" do
    {log, _job_id} = run(FailedHandler)

    assert log =~ "trace-corr"
    assert log =~ "job_id"
    assert log =~ "failed"
    assert log =~ "boom"
  end

  test "a discarded job's log carries its job id and trace id" do
    {log, _job_id} = run(DiscardedHandler)

    assert log =~ "trace-corr"
    assert log =~ "job_id"
    assert log =~ "discarded"
  end

  # One turn of the worker loop, driven directly so a single job is processed
  # and the test never depends on the poll timer.
  defp run(handler) do
    uri = "viking://corr/#{System.unique_integer([:positive])}.md"
    {:ok, job_id} = Storage.enqueue_job(:embed, %{uri: uri, content: "c", _trace: @trace})

    state = %{
      handler: handler,
      worker_id: "corr-#{System.unique_integer([:positive])}",
      failures: 0
    }

    log = capture_log(fn -> JobWorker.handle_continue(:work, state) end)

    {log, job_id}
  end
end
