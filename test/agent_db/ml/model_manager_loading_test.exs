defmodule AgentDb.ML.ModelManagerLoadingTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.{ExitingLoader, FakeLoader, ModelManager, RaisingLoader}

  @model_id "sentence-transformers/all-MiniLM-L6-v2"
  @llm_id "Qwen/Qwen3-0.6B"

  setup do
    # ModelManager is a child of the application supervisor. Swap that one child
    # out rather than stopping the whole application, so the rest of the tree
    # (endpoint, workers) is left alone.
    :ok = Supervisor.terminate_child(AgentDb.Supervisor, ModelManager)
    :ok = AgentDb.ML.FakeCallLog.start()

    cache = Path.join(System.tmp_dir!(), "agent_db_mm_#{:erlang.unique_integer([:positive])}")

    Application.put_env(:agent_db, :model_cache_dir, cache)
    Application.put_env(:agent_db, :embedding_model, @model_id)
    Application.put_env(:agent_db, :llm_model, @llm_id)
    # Keep the grace period short so a test does not sit through the default.
    Application.put_env(:agent_db, :model_load_grace_ms, 300)

    on_exit(fn ->
      Application.delete_env(:agent_db, :model_cache_dir)
      Application.delete_env(:agent_db, :embedding_model)
      Application.delete_env(:agent_db, :llm_model)
      Application.delete_env(:agent_db, :model_load_grace_ms)
      File.rm_rf(cache)
      AgentDb.StorageContract.Helpers.restore_child(ModelManager)
    end)

    %{cache: cache}
  end

  defp start_manager(loader) do
    start_supervised!({ModelManager, [ml_backend: :exla, loader: loader]})
  end

  # A cached weights file means the download step is skipped and the load runs.
  defp cache_model(cache, model_id) do
    dir = Path.join(cache, model_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "model.safetensors"), "not-real-weights")
    :ok
  end

  describe "loading a cached model" do
    setup %{cache: cache} do
      :ok = cache_model(cache, @model_id)
      start_manager(FakeLoader)
      :ok
    end

    test "produces an embedding and reports the model as loaded" do
      assert {:ok, [embedding]} = ModelManager.embed(["hello"])
      assert Nx.shape(embedding) == {2}
      assert %{embedding: %{loaded: true}} = ModelManager.model_status()
    end

    test "does not reload the model on a second request" do
      # Cleared here rather than in setup: a load spawned by an earlier test can
      # still be in flight and would otherwise record into this test's log.
      AgentDb.ML.FakeCallLog.clear()
      assert {:ok, [_]} = ModelManager.embed(["one"])
      assert {:ok, [_]} = ModelManager.embed(["two"])

      assert [{@model_id, _}] = AgentDb.ML.FakeCallLog.entries(:load_model)
      assert [{@model_id, _}] = AgentDb.ML.FakeCallLog.entries(:load_tokenizer)
    end

    test "passes the configured backend to the loader" do
      assert {:ok, [_]} = ModelManager.embed(["hello"])

      assert [{@model_id, opts}] = AgentDb.ML.FakeCallLog.entries(:load_model)
      assert opts[:backend] == :cpu
    end

    test "loads and runs the summarization model", %{cache: cache} do
      :ok = cache_model(cache, @llm_id)

      assert {:ok, "generated summary"} = ModelManager.summarize("hi")
      assert %{llm: %{loaded: true}} = ModelManager.model_status()
    end
  end

  describe "an unavailable model" do
    setup %{cache: cache} do
      start_manager(FakeLoader)
      %{cache: cache}
    end

    test "reports an error and does not terminate the caller" do
      # Nothing cached, and remote downloads are skipped under test.
      assert {:error, {:model_not_found, _path}} = ModelManager.embed(["hello"])
    end

    test "leaves later requests serviceable and retries the load", %{cache: cache} do
      assert {:error, {:model_not_found, _}} = ModelManager.embed(["hello"])
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()

      :ok = cache_model(cache, @model_id)
      assert {:ok, [_]} = ModelManager.embed(["hello"])
    end

    test "a loader that exits is reported, not propagated", %{cache: cache} do
      :ok = cache_model(cache, @model_id)
      :sys.replace_state(ModelManager, &put_in(&1.config.loader, ExitingLoader))

      assert {:error, {:model_load_failed, {:exit, :no_such_client}}} =
               ModelManager.embed(["hello"])

      assert %{embedding: %{loaded: false}} = ModelManager.model_status()
    end

    test "a loader that raises is reported, not propagated", %{cache: cache} do
      :ok = cache_model(cache, @model_id)
      :sys.replace_state(ModelManager, &put_in(&1.config.loader, RaisingLoader))

      assert {:error, {:model_load_failed, %RuntimeError{}}} = ModelManager.embed(["hello"])
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()
    end
  end
end
