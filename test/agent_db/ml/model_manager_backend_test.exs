defmodule AgentDb.ML.ModelManagerBackendTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.FakeLoader
  alias AgentDb.ML.ModelManager

  @model_id "sentence-transformers/all-MiniLM-L6-v2"

  setup do
    :ok = Supervisor.terminate_child(AgentDb.Supervisor, ModelManager)
    :ok = AgentDb.ML.FakeCallLog.start()

    cache = AgentDb.Test.Scratch.dir("agent_db_mmb")
    Application.put_env(:agent_db, :model_cache_dir, cache)
    Application.put_env(:agent_db, :embedding_model, @model_id)
    Application.put_env(:agent_db, :model_load_grace_ms, 300)

    on_exit(fn ->
      Application.delete_env(:agent_db, :model_cache_dir)
      Application.delete_env(:agent_db, :embedding_model)
      Application.delete_env(:agent_db, :model_load_grace_ms)
      Application.delete_env(:agent_db, :ml_backend)
      File.rm_rf(cache)
      AgentDb.StorageContract.Helpers.restore_child(ModelManager)
    end)

    %{cache: cache}
  end

  defp cache_model(cache, model_id) do
    dir = Path.join(cache, model_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "model.safetensors"), "not-real-weights")
  end

  test "explicit :exla backend loads and embeds", %{cache: cache} do
    :ok = cache_model(cache, @model_id)
    start_supervised!({ModelManager, [ml_backend: :exla, loader: FakeLoader]})

    assert ModelManager.backend() == :exla
    assert {:ok, [_]} = ModelManager.embed(["hello"])
  end

  test "emlx falls back to exla when unavailable", %{cache: cache} do
    :ok = cache_model(cache, @model_id)
    start_supervised!({ModelManager, [ml_backend: :emlx, loader: FakeLoader]})

    # On Linux (no Apple Silicon) EMLX is unavailable; the manager still
    # serves through the EXLA fallback instead of failing.
    assert {:ok, [_]} = ModelManager.embed(["hello"])
    assert ModelManager.backend() == :emlx
  end
end
