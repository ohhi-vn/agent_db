defmodule AgentDb.CacheTest do
  @moduledoc """
  The read cache's own behaviour.

  The guarantee a caller depends on is that the cache is never ahead of the
  store, so what these assert is that a write drops what it can have made
  stale and that nothing else does.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Cache

  setup do
    # The tables belong to the store's supervision tree, so they exist only while
    # it is running. A test that killed the owner, or that ran after another
    # file stopped the application, would otherwise be asserting against tables
    # that are not there.
    AgentDb.StorageContract.Helpers.restart_app()
    Cache.clear()
    :ok
  end

  test "both tables exist and entries round-trip" do
    assert :ets.whereis(Cache.node_cache()) != :undefined
    assert :ets.whereis(Cache.dir_cache()) != :undefined

    assert :miss = Cache.get_node("viking://x")
    assert :ok = Cache.put_node("viking://x", %{content: "hi"})
    assert {:ok, %{content: "hi"}} = Cache.get_node("viking://x")

    assert :miss = Cache.get_dir("viking://x")
    assert :ok = Cache.put_dir("viking://x", MapSet.new(["a.md"]))
    assert {:ok, %MapSet{}} = Cache.get_dir("viking://x")
  end

  test "a killed owner is restarted by the supervisor with empty tables" do
    Cache.put_node("viking://keep", %{content: "x"})
    Cache.put_dir("viking://", MapSet.new(["keep"]))

    pid = Process.whereis(Cache)
    assert pid != nil
    Process.exit(pid, :kill)

    new_pid = await_restart(pid)
    assert new_pid != pid

    # Correctness never depended on what was cached, so a lost cache is a
    # rebuild rather than a loss.
    assert :miss = Cache.get_node("viking://keep")
    assert :miss = Cache.get_dir("viking://")
    assert %{node_cache: 0, dir_cache: 0} = Cache.stats()
  end

  describe "a write" do
    test "drops the node, its parent's listing and every ancestor's" do
      # Warmed the way a read path would populate them.
      Cache.put_node("viking://resources/p/docs/a.md", %{content: "doc"})
      Cache.put_dir("viking://resources/p/docs", MapSet.new(["a.md"]))
      Cache.put_dir("viking://resources/p", MapSet.new(["docs"]))
      Cache.put_dir("viking://resources", MapSet.new(["p"]))
      Cache.put_dir("viking://", MapSet.new(["resources"]))

      Cache.invalidate_write("viking://resources/p/docs/a.md")

      assert :miss = Cache.get_node("viking://resources/p/docs/a.md")
      assert :miss = Cache.get_dir("viking://resources/p/docs")
      assert :miss = Cache.get_dir("viking://resources/p")
      assert :miss = Cache.get_dir("viking://resources")
      assert :miss = Cache.get_dir("viking://")
    end

    test "leaves unrelated subtrees alone" do
      Cache.put_node("viking://resources/other/f.md", %{content: "unrelated"})
      Cache.put_dir("viking://resources/other", MapSet.new(["f.md"]))

      Cache.invalidate_write("viking://resources/p/docs/a.md")

      # A write elsewhere cannot have changed these, and rebuilding them would
      # only cost a query.
      assert {:ok, %{content: "unrelated"}} = Cache.get_node("viking://resources/other/f.md")
      assert {:ok, _} = Cache.get_dir("viking://resources/other")
    end

    test "at the root invalidates only the root listing" do
      Cache.put_dir("viking://", MapSet.new(["old"]))

      Cache.invalidate_write("viking://resources")

      assert :miss = Cache.get_dir("viking://")
    end
  end

  describe "a removal" do
    test "drops the whole subtree, not just the entry at the URI" do
      inside = "viking://resources/gone/deep/a.md"
      Cache.put_node(inside, %{content: "doomed"})
      Cache.put_dir("viking://resources/gone/deep", MapSet.new(["a.md"]))
      Cache.put_dir("viking://resources/gone", MapSet.new(["deep"]))

      Cache.invalidate_removal("viking://resources/gone")

      assert :miss = Cache.get_node(inside)
      assert :miss = Cache.get_dir("viking://resources/gone/deep")
      assert :miss = Cache.get_dir("viking://resources/gone")
    end

    test "leaves a similarly named sibling alone" do
      # The prefix is `gone/`, so `gone-extra` is not inside the removal.
      Cache.put_node("viking://resources/gone-extra/a.md", %{content: "kept"})

      Cache.invalidate_removal("viking://resources/gone")

      assert {:ok, %{content: "kept"}} = Cache.get_node("viking://resources/gone-extra/a.md")
    end
  end

  defp await_restart(old_pid), do: wait(fn -> restarted(old_pid) end)

  defp restarted(old_pid) do
    case Process.whereis(Cache) do
      nil -> nil
      ^old_pid -> nil
      new -> new
    end
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
