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
end
