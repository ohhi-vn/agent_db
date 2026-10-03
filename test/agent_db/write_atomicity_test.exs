defmodule AgentDb.WriteAtomicityTest do
  use ExUnit.Case, async: false

  alias AgentDb.Cache
  alias AgentDb.Test.Fakes.Storage

  setup do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Application.put_env(:agent_db, :storage_adapter, Storage)
    Application.put_env(:agent_db, :inference_provider, AgentDb.Test.Fakes.Inference)
    :ok = AgentDb.StorageContract.Helpers.restart_app()
    Storage.reset()
    Cache.clear()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :storage_adapter)
      Application.delete_env(:agent_db, :inference_provider)
      AgentDb.Test.Script.clear(:fake_storage)
      AgentDb.Test.Script.clear(:fake_inference)
      :ok = AgentDb.StorageContract.Helpers.restart_app()
    end)

    :ok
  end

  test "failed enqueue leaves a new document absent with unchanged queue" do
    Storage.stub(:enqueue_job, {:error, :queue_unavailable})
    before_jobs = Storage.recorded_jobs()

    assert {:error, :queue_unavailable} =
             AgentDb.write("viking://resources/atomic/new.md", "content")

    assert {:error, :not_found} = AgentDb.read("viking://resources/atomic/new.md")
    assert Storage.recorded_jobs() == before_jobs
  end

  test "failed enqueue preserves an existing document and its cache" do
    assert :ok = AgentDb.write("viking://resources/atomic/existing.md", "original")
    assert {:ok, "original"} = AgentDb.read("viking://resources/atomic/existing.md")

    Storage.stub(:enqueue_job, {:error, :queue_unavailable})

    assert {:error, :queue_unavailable} =
             AgentDb.write("viking://resources/atomic/existing.md", "replacement")

    AgentDb.Test.Script.clear(:fake_storage)
    assert {:ok, "original"} = AgentDb.read("viking://resources/atomic/existing.md")
  end

  test "successful async write enqueues required jobs" do
    assert :ok = AgentDb.write("viking://resources/atomic/async.md", "content")
    assert {:ok, "content"} = AgentDb.read("viking://resources/atomic/async.md")

    jobs = Storage.recorded_jobs()
    uris = for job <- jobs, do: job.payload["uri"]
    assert "viking://resources/atomic/async.md" in uris
  end

  test "successful sync write reports completion" do
    # Workers are running with fake inference, so jobs complete quickly.
    assert :ok =
             AgentDb.write("viking://resources/atomic/sync.md", "content",
               async: false,
               sync_timeout_ms: 5_000
             )

    assert {:ok, "content"} = AgentDb.read("viking://resources/atomic/sync.md")
  end
end
