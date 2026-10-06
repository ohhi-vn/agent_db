defmodule AgentDb.HybridSearchTest do
  use ExUnit.Case, async: false

  alias AgentDb.Application.Search

  setup do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    :ok = AgentDb.StorageContract.Helpers.restart_app()
    :ok = AgentDb.StorageContract.Helpers.stop_workers()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)
    :ok
  end

  test "a failed leg returns a classified error without exiting the caller" do
    :ok = AgentDb.write("viking://resources/hybrid/a.md", "hello world content")

    # No embedding model in test (and no sqlite-vec), so the vector leg fails.
    # The call must return an error tuple, not exit.
    result = Search.search("hello", mode: :hybrid)
    assert match?({:error, _}, result)

    # The caller survives: a subsequent keyword search still works.
    assert {:ok, results} = Search.search("hello", mode: :keyword)
    assert Enum.any?(results, &(&1.uri == "viking://resources/hybrid/a.md"))
  end

  test "keyword leg still works after a failed hybrid" do
    :ok = AgentDb.write("viking://resources/hybrid/b.md", "unique keyword xyzzy")
    assert match?({:error, _}, Search.search("xyzzy", mode: :hybrid))
    assert {:ok, [_ | _]} = Search.search("xyzzy", mode: :keyword)
  end

  # -- hybrid_weights shapes (tuple and keyword list fuse identically) --

  defmodule WeightedFakes do
    @moduledoc false
    # Both legs served by fakes with deterministic vectors, so fusion is
    # observable without a model or a vector extension.
    use ExUnit.Case, async: false

    alias AgentDb.Application.Search
    alias AgentDb.Test.Fakes

    setup do
      Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
      Application.put_env(:agent_db, :storage_adapter, Fakes.Storage)
      Application.put_env(:agent_db, :inference_provider, Fakes.Inference)
      Fakes.Storage.reset()
      :ok = AgentDb.StorageContract.Helpers.restart_app()
      :ok = AgentDb.StorageContract.Helpers.stop_workers()

      on_exit(fn ->
        Application.delete_env(:agent_db, :data_dir)
        Application.delete_env(:agent_db, :storage_adapter)
        Application.delete_env(:agent_db, :inference_provider)
        AgentDb.Test.Script.clear(:fake_storage)
        AgentDb.Test.Script.clear(:fake_inference)
      end)

      :ok
    end

    test "tuple and keyword-list weights rank identically, and weights matter" do
      :ok = AgentDb.write("viking://resources/weights/a.md", "apple orchard")
      :ok = AgentDb.write("viking://resources/weights/b.md", "apple core")

      # The vector leg hits only b: its stored bytes equal the query embedding.
      {:ok, [query_vec]} = Fakes.Inference.embed(["apple"])
      store_vec("viking://resources/weights/b.md", query_vec)

      assert {:ok, tuple} = Search.search("apple", mode: :hybrid, hybrid_weights: {0.5, 0.5})

      assert {:ok, listed} =
               Search.search("apple", mode: :hybrid, hybrid_weights: [keyword: 0.5, vector: 0.5])

      # b is found by both legs, so it outranks the keyword-only hit either way.
      assert Enum.map(tuple, & &1.uri) == [
               "viking://resources/weights/b.md",
               "viking://resources/weights/a.md"
             ]

      assert tuple == listed

      # Skewed weights are honored, identically in both shapes: keyword-only
      # ranking puts the URI-first hit on top instead.
      assert {:ok, kw_tuple} = Search.search("apple", mode: :hybrid, hybrid_weights: {1.0, 0.0})

      assert {:ok, kw_list} =
               Search.search("apple", mode: :hybrid, hybrid_weights: [keyword: 1.0, vector: 0.0])

      assert Enum.map(kw_tuple, & &1.uri) == [
               "viking://resources/weights/a.md",
               "viking://resources/weights/b.md"
             ]

      assert kw_tuple == kw_list
    end

    defp store_vec(uri, bytes) do
      {:ok, job_id} = Fakes.Storage.enqueue_job(:embed, %{uri: uri, content: ""})
      {:ok, _} = Fakes.Storage.dequeue_job([:embed])
      {:ok, :stored} = Fakes.Storage.put_embedding_result(job_id, uri, bytes)
      :ok
    end
  end
end
