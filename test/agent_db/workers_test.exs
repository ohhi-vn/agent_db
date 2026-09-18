defmodule AgentDb.WorkersTest do
  use ExUnit.Case, async: false

  alias AgentDb.Workers.EmbeddingWorker
  alias AgentDb.Workers.SummarizationWorker

  setup do
    # Workers are already started by the application
    # Just verify they exist
    pid = GenServer.whereis({:via, :global, "embedding_worker_1"})
    assert pid != nil
    pid2 = GenServer.whereis({:via, :global, "summarization_worker_1"})
    assert pid2 != nil

    on_exit(fn ->
      # Don't stop shared workers
      :ok
    end)

    :ok
  end

  describe "EmbeddingWorker" do
    test "is running under supervision" do
      pid = GenServer.whereis({:via, :global, "embedding_worker_1"})
      assert pid != nil
    end
  end

  describe "SummarizationWorker" do
    test "is running under supervision" do
      pid = GenServer.whereis({:via, :global, "summarization_worker_1"})
      assert pid != nil
    end
  end
end