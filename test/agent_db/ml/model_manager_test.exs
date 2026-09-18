defmodule AgentDb.ML.ModelManagerTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.ModelManager
  alias AgentDb.Config

  setup do
    # Use the already running ModelManager from the application
    # Just verify it's running
    pid = GenServer.whereis(ModelManager)
    assert pid != nil
    
    on_exit(fn ->
      # Don't stop the shared ModelManager
    end)

    :ok
  end

  describe "model_status/0" do
    test "returns status map with embedding and llm info" do
      status = ModelManager.model_status()

      assert is_map(status)
      assert Map.has_key?(status, :embedding)
      assert Map.has_key?(status, :llm)
      assert Map.has_key?(status, :queue)
    end
  end

  describe "embed/1" do
    test "returns error when model not available" do
      # Since we don't have actual models in test env, this should fail gracefully
      result = ModelManager.embed(["test text"])

      # Should return error tuple (model not loaded)
      assert match?({:error, _}, result)
    end
  end

  describe "summarize/2" do
    test "returns error when model not available" do
      result = ModelManager.summarize("test prompt", max_tokens: 100)

      # Should return error tuple (model not loaded)
      assert match?({:error, _}, result)
    end
  end
end