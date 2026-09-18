defmodule AgentDb.CacheTest do
  use ExUnit.Case, async: false

  alias AgentDb.Cache.{Invalidate, Owner}

  setup do
    Owner.clear()
    :ok
  end

  test "owner creates both tables and helpers round-trip" do
    assert :ets.whereis(Owner.node_cache()) != :undefined
    assert :ets.whereis(Owner.dir_cache()) != :undefined

    assert :miss = Owner.get_node("viking://x")
    Owner.put_node("viking://x", %{content: "hi"})
    assert {:ok, %{content: "hi"}} = Owner.get_node("viking://x")

    assert :miss = Owner.get_dir("viking://x")
    Owner.put_dir("viking://x", MapSet.new(["a.md"]))
    assert {:ok, %MapSet{}} = Owner.get_dir("viking://x")

    Owner.drop_node("viking://x")
    assert :miss = Owner.get_node("viking://x")
  end

  test "killed owner is restarted by the supervisor and tables are recreated empty" do
    Owner.put_node("viking://keep", %{content: "x"})
    Owner.put_dir("viking://", MapSet.new(["keep"]))

    pid = GenServer.whereis(Owner)
    assert pid != nil
    Process.exit(pid, :kill)

    # supervisor restarts it synchronously enough for a whereis retry loop
    new_pid = await_restart(pid)
    assert new_pid != pid
    assert :ets.whereis(Owner.node_cache()) != :undefined
    assert :ets.whereis(Owner.dir_cache()) != :undefined
    assert :miss = Owner.get_node("viking://keep")
    assert :miss = Owner.get_dir("viking://")
    assert %{node_cache: 0, dir_cache: 0} = Owner.stats()
  end

  test "invalidation on write drops node, parent dir, and ancestor dirs" do
    # warm cache with the shape a read path would produce
    Owner.put_node("viking://resources/p/docs/a.md", %{content: "doc"})
    Owner.put_dir("viking://resources/p/docs", MapSet.new(["a.md"]))
    Owner.put_dir("viking://resources/p", MapSet.new(["docs"]))
    Owner.put_dir("viking://resources", MapSet.new(["p"]))
    Owner.put_dir("viking://", MapSet.new(["resources"]))

    Invalidate.on_write("viking://resources/p/docs/a.md")

    assert :miss = Owner.get_node("viking://resources/p/docs/a.md")
    assert :miss = Owner.get_dir("viking://resources/p/docs")
    assert :miss = Owner.get_dir("viking://resources/p")
    assert :miss = Owner.get_dir("viking://resources")
    assert :miss = Owner.get_dir("viking://")
  end

  test "invalidation preserves unrelated subtrees" do
    Owner.put_node("viking://resources/other/f.md", %{content: "unrelated"})
    Owner.put_dir("viking://resources/other", MapSet.new(["f.md"]))

    Invalidate.on_write("viking://resources/p/docs/a.md")

    assert {:ok, %{content: "unrelated"}} = Owner.get_node("viking://resources/other/f.md")
    assert {:ok, _} = Owner.get_dir("viking://resources/other")
  end

  test "root-level write invalidates only root dir entry" do
    Owner.put_dir("viking://", MapSet.new(["old"]))

    Invalidate.on_write("viking://resources")

    assert :miss = Owner.get_dir("viking://")
  end

  defp await_restart(old_pid) do
    wait(fn ->
      case GenServer.whereis(Owner) do
        nil -> nil
        ^old_pid -> nil
        new -> new
      end
    end)
  end

  defp wait(fun, tries \\ 200)

  defp wait(_fun, 0), do: flunk("condition not met in time")

  defp wait(fun, tries) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait(fun, tries - 1)

      value ->
        value
    end
  end
end
