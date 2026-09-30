defmodule AgentDb.ML.ModelLoadStateTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.{FakeCallLog, FakeLoader, ModelManager, RaisingLoader, SlowLoader}

  @llm_id "Qwen/Qwen3-0.6B"

  setup do
    :ok = Supervisor.terminate_child(AgentDb.Supervisor, ModelManager)

    # The workers claim jobs and ask whatever manager is registered for a
    # model. While this test deliberately leaves a manager unconfigured, a
    # worker asking it would start a load the test never asked for, against a
    # model id that does not exist.
    :ok = AgentDb.StorageContract.Helpers.stop_workers()

    cache = Path.join(System.tmp_dir!(), "agent_db_ls_#{:erlang.unique_integer([:positive])}")

    # A distinct model id per test. The call log is shared and a load from an
    # earlier test can still be in flight, so entries are filtered by the id
    # rather than counted, which would be racy.
    model_id = "test/model-#{:erlang.unique_integer([:positive])}"

    Application.put_env(:agent_db, :model_cache_dir, cache)
    Application.put_env(:agent_db, :embedding_model, model_id)
    Application.put_env(:agent_db, :llm_model, @llm_id)
    Application.put_env(:agent_db, :model_load_grace_ms, 300)

    on_exit(fn ->
      for key <- [
            :model_cache_dir,
            :embedding_model,
            :llm_model,
            :model_load_grace_ms
          ] do
        Application.delete_env(:agent_db, key)
      end

      File.rm_rf(cache)
      AgentDb.StorageContract.Helpers.restore_child(ModelManager)

      for worker <- [AgentDb.Workers.Embedding, AgentDb.Workers.Summarization] do
        AgentDb.StorageContract.Helpers.restore_child(worker)
      end
    end)

    %{cache: cache, model_id: model_id}
  end

  defp start_manager(loader, grace \\ nil) do
    if grace, do: Application.put_env(:agent_db, :model_load_grace_ms, grace)
    :ok = AgentDb.ML.FakeCallLog.start()
    start_supervised!({ModelManager, []})

    :sys.replace_state(ModelManager, fn state ->
      %{state | config: Map.put(state.config, :loader, loader)}
    end)
  end

  defp cache_model(cache, model_id) do
    dir = Path.join(cache, model_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "model.safetensors"), "not-real-weights")
    :ok
  end

  defp status(role), do: GenServer.call(ModelManager, {:load_status, role}, 5_000)

  # Load calls recorded for this test's own model id.
  defp load_calls(model_id) do
    for {^model_id, _opts} <- FakeCallLog.entries(:load_model), do: :loaded
  end

  defp set_grace(ms), do: Application.put_env(:agent_db, :model_load_grace_ms, ms)

  # The load runs outside the call that started it, so a caller can return
  # before the load has reached the library at all.
  defp await_settled(role, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_settled(role, deadline)
  end

  defp do_await_settled(role, deadline) do
    case status(role) do
      :loading ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(25)
          do_await_settled(role, deadline)
        end

      other ->
        other
    end
  end

  defp model_status do
    ModelManager.model_status()
  end

  describe "load status" do
    test "starts idle and reports loading once a load begins", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(FakeLoader)

      assert status(:embedding) == :idle

      # A very short grace means the caller gives up before the load lands,
      # which is exactly the state worth observing from outside.
      set_grace(0)
      assert {:error, :model_loading} = ModelManager.embed(["hello"])
      assert status(:embedding) == :loading
    end

    test "reports ready once the model is adopted", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(FakeLoader)

      assert {:ok, [_]} = ModelManager.embed(["hello"])
      assert status(:embedding) == :ready
      assert model_status().embedding.state == :ready
    end

    test "reports failed after a load that cannot succeed", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(RaisingLoader)

      assert {:error, {:model_load_failed, %RuntimeError{}}} = ModelManager.embed(["hello"])
      assert {:failed, {:model_load_failed, %RuntimeError{}}} = status(:embedding)
      assert model_status().embedding.state == :failed
    end
  end

  describe "a load reported as loading" do
    test "is distinguishable from a load that failed", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(RaisingLoader, 0)

      # Grace of 0: the caller does not wait, so it sees :model_loading and has
      # not yet learned whether the load will succeed.
      assert {:error, :model_loading} = ModelManager.embed(["hello"])
    end

    test "is safe to repeat and succeeds once ready", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(FakeLoader, 0)

      assert {:error, :model_loading} = ModelManager.embed(["first"])

      # A generous grace now covers the in-flight load, so the retry is served
      # without the caller having to poll.
      set_grace(5_000)
      assert {:ok, [_]} = ModelManager.embed(["second"])
    end
  end

  describe "the grace period" do
    test "a cached model completes inside the default grace with no visible retry", %{
      cache: cache,
      model_id: model_id
    } do
      :ok = cache_model(cache, model_id)
      start_manager(FakeLoader)
      set_grace(5_000)

      # One call, one load, one inference: the caller never sees :model_loading.
      assert {:ok, [_]} = ModelManager.embed(["hello"])
      assert [_] = load_calls(model_id)
    end

    test "a short grace reports loading where a long one would not", %{
      cache: cache,
      model_id: model_id
    } do
      :ok = cache_model(cache, model_id)
      # A loader slow enough that no reasonable grace covers it.
      start_manager(SlowLoader)
      set_grace(50)

      assert {:error, :model_loading} = ModelManager.embed(["hello"])
    end
  end

  describe "concurrency" do
    test "many concurrent first calls produce one load", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(SlowLoader)
      set_grace(10)

      # Task.yield_many wraps each result in {:ok, _}; unwrap it so the
      # assertions below see what embed/1 actually returned.
      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> ModelManager.embed(["x"]) end) end)
        |> Task.yield_many(10_000)
        |> Enum.map(fn
          {task, nil} -> Task.await(task, 2_000)
          {_task, {:ok, result}} -> result
          {_task, other} -> other
        end)

      # One call may win the race and serve the request; the rest are told to
      # retry. None of them may start a second load.
      assert Enum.count(results, &match?({:ok, _}, &1)) <= 1
      assert Enum.count(results, &match?({:error, :model_loading}, &1)) >= 1

      assert :ready = await_settled(:embedding)
      assert [_] = load_calls(model_id)
    end

    test "both roles reach ready when they load at the same time", %{
      cache: cache,
      model_id: model_id
    } do
      # Both roles need cached weights, or one load short-circuits and the two
      # loads never overlap -- which is the only state this test is about.
      :ok = cache_model(cache, model_id)
      :ok = cache_model(cache, @llm_id)
      start_manager(SlowLoader)
      set_grace(0)

      # Grace of 0 returns before either load can settle, so the second call
      # arrives while the first is still in flight. SlowLoader keeps both in
      # flight long enough for that to hold.
      assert {:error, :model_loading} = ModelManager.embed(["a"])
      assert {:error, :model_loading} = ModelManager.summarize("b")

      # Neither role may be left reporting as loading: a load for one must not
      # discard the result of the other.
      assert :ready = await_settled(:embedding)
      assert :ready = await_settled(:llm)

      set_grace(5_000)
      assert {:ok, [_]} = ModelManager.embed(["a"])
      assert {:ok, "generated summary"} = ModelManager.summarize("b")
    end
  end

  describe "a load that outlives the manager that started it" do
    test "its result is not adopted by the manager that replaced it", %{
      cache: cache,
      model_id: model_id
    } do
      :ok = cache_model(cache, model_id)
      start_manager(SlowLoader)
      set_grace(0)

      # Starts a load, then the manager goes away while it is still running.
      assert {:error, :model_loading} = ModelManager.embed(["a"])

      stop_supervised!(ModelManager)
      start_supervised!({ModelManager, id: :replacement})

      # SlowLoader needs ~3s (tokenizer then model) before the abandoned load
      # casts its result. Wait past that, so the result is guaranteed to have
      # been delivered to the manager that replaced it -- otherwise this would
      # pass on a fresh manager's idle state without the guard ever running.
      Process.sleep(4_000)

      # A fresh manager has started no load, so it records no reference for
      # this role. The late result matches nothing and must be discarded
      # rather than written into a state that never loaded anything.
      assert :idle = status(:embedding)
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()
    end
  end

  describe "responsiveness" do
    test "model status answers while a load is in progress", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(SlowLoader)
      set_grace(0)

      assert {:error, :model_loading} = ModelManager.embed(["hello"])
      assert status(:embedding) == :loading

      # A state read must not queue behind the load. This is the wedge the
      # design removes: previously this took the full duration of the load.
      {elapsed, result} = :timer.tc(fn -> model_status() end)
      assert is_map(result)
      assert elapsed < 1_000_000
    end

    test "model status answers while a run is in progress", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, model_id)
      start_manager(SlowLoader)
      set_grace(0)

      # The first call starts the load and is told it is loading; later calls
      # find the model ready and reach a run.
      assert {:error, :model_loading} = ModelManager.embed(["hello"])
      assert :ready = await_settled(:embedding)

      task = Task.async(fn -> ModelManager.embed(["hello"]) end)
      Task.yield(task, 200)

      # A run holds the model for the length of the run. A state read must not
      # queue behind it, which is what it did when runs happened inside the
      # manager process.
      {elapsed, result} = :timer.tc(fn -> model_status() end)
      assert is_map(result)
      assert elapsed < 1_000_000

      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "summarization" do
    test "reports loading then succeeds", %{cache: cache, model_id: model_id} do
      :ok = cache_model(cache, @llm_id)
      start_manager(FakeLoader, 0)

      assert {:error, :model_loading} = ModelManager.summarize("hi")
      set_grace(5_000)
      assert {:ok, "generated summary"} = ModelManager.summarize("hi")
    end
  end

  describe "status measurements" do
    test "reports last inference latency per role and VM memory", %{
      cache: cache,
      model_id: model_id
    } do
      :ok = cache_model(cache, model_id)
      start_manager(FakeLoader)

      # Nothing has run yet: latency is unknown rather than zero.
      assert model_status().embedding.last_latency_ms == nil
      assert model_status().llm.last_latency_ms == nil

      assert {:ok, [_]} = ModelManager.embed(["hello"])

      latency = model_status().embedding.last_latency_ms
      assert is_integer(latency) and latency >= 0

      # The other role never ran, so it stays unknown.
      assert model_status().llm.last_latency_ms == nil

      memory = model_status().memory_bytes
      assert is_integer(memory) and memory > 0
    end
  end
end
