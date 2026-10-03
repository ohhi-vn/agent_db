defmodule AgentDb.ML.ModelManagerTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.ModelManager

  setup do
    # Use the already running ModelManager from the application
    # Just verify it's running
    pid = GenServer.whereis(ModelManager)
    assert pid != nil

    on_exit(fn ->
      nil
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
      # The manager knows how many calls are using the model, which is the one
      # queue-shaped fact it is actually the owner of.
      assert Map.has_key?(status, :in_flight)
    end

    test "each role reports its own load duration and last inference latency" do
      status = ModelManager.model_status()

      for role <- [:embedding, :llm] do
        assert Map.has_key?(Map.get(status, role, %{}), :last_load_ms)
        assert Map.has_key?(Map.get(status, role, %{}), :last_latency_ms)
      end
    end
  end

  # These use the shared ModelManager, so whether a model is cached depends on
  # the host. What is asserted here is the contract either way: a well-formed
  # answer that never crashes the caller.

  describe "embed/1" do
    test "answers with 384-dim embeddings or a classified error" do
      case ModelManager.embed(["test text"]) do
        {:ok, embeddings} ->
          assert [%Nx.Tensor{} = embedding] = embeddings
          assert Nx.shape(embedding) == {384}

        {:error, reason} ->
          assert is_tuple(reason) or is_atom(reason)
      end
    end
  end

  describe "summarize/2" do
    test "answers with text or a classified error" do
      case ModelManager.summarize("test prompt", max_tokens: 100) do
        {:ok, text} -> assert is_binary(text)
        {:error, reason} -> assert is_tuple(reason) or is_atom(reason)
      end
    end
  end
end
