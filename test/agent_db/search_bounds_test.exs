defmodule AgentDb.SearchBoundsTest do
  @moduledoc """
  How many results a search returns, and what happens when it is asked for an
  unusable number.

  `:top_k` is the store's documented bound on results. The vector and hybrid
  legs have always applied it; the keyword leg did not, so a common term
  returned every matching document. These are the assertions that hold all
  three legs to the same contract.
  """
  use ExUnit.Case, async: false

  setup context do
    AgentDb.Cache.clear()

    # The test data directory is shared, so every test writes below its own
    # prefix. Otherwise a document left by one test is a match for the next
    # one's query, and the bound being asserted is not the one under test.
    prefix = "viking://resources/bounds/#{context.line}"
    on_exit(fn -> AgentDb.rm(prefix) end)

    {:ok, prefix: prefix}
  end

  defp write_many(prefix, count, body) do
    for n <- 1..count do
      :ok =
        AgentDb.write(
          "#{prefix}/doc#{String.pad_leading(to_string(n), 3, "0")}.md",
          body
        )
    end
  end

  describe "keyword search" do
    test "returns at most top_k results", %{prefix: prefix} do
      write_many(prefix, 12, "a repeated marker term")

      assert {:ok, results} = AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 3)
      assert length(results) == 3
    end

    test "defaults to ten results", %{prefix: prefix} do
      write_many(prefix, 15, "a repeated marker term")

      assert {:ok, results} = AgentDb.search("marker", mode: :keyword, scope: prefix)
      assert length(results) == 10
    end

    test "returns everything when fewer documents match than the bound", %{prefix: prefix} do
      write_many(prefix, 3, "a rare marker term")

      assert {:ok, results} = AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 50)
      assert length(results) == 3
    end

    test "results are ordered by URI, so the same query answers the same way", %{prefix: prefix} do
      write_many(prefix, 6, "a repeated marker term")

      assert {:ok, first} = AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 4)
      assert {:ok, again} = AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 4)

      uris = Enum.map(first, & &1.uri)
      assert uris == Enum.map(again, & &1.uri)
      assert uris == Enum.sort(uris)
    end

    test "a scope and a bound apply together", %{prefix: prefix} do
      for n <- 1..5, do: :ok = AgentDb.write("#{prefix}/in/doc#{n}.md", "marker")
      for n <- 1..5, do: :ok = AgentDb.write("#{prefix}/out/doc#{n}.md", "marker")

      assert {:ok, results} =
               AgentDb.search("marker", mode: :keyword, scope: "#{prefix}/in", top_k: 2)

      assert length(results) == 2

      for result <- results do
        assert String.starts_with?(result.uri, "#{prefix}/in/")
      end
    end
  end

  describe "an unusable bound" do
    test "zero is refused rather than treated as no bound", %{prefix: prefix} do
      write_many(prefix, 3, "marker")

      assert {:error, {:invalid_limit, 0}} =
               AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 0)
    end

    test "a negative bound is refused", %{prefix: prefix} do
      write_many(prefix, 3, "marker")

      assert {:error, {:invalid_limit, -1}} =
               AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: -1)
    end

    test "a bound past the maximum is refused", %{prefix: prefix} do
      write_many(prefix, 3, "marker")

      assert {:error, {:invalid_limit, 5000}} =
               AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 5_000)
    end

    test "the largest allowed bound is accepted", %{prefix: prefix} do
      write_many(prefix, 3, "marker")

      assert {:ok, results} = AgentDb.search("marker", mode: :keyword, scope: prefix, top_k: 200)
      assert length(results) == 3
    end
  end

  describe "the other legs" do
    test "vector search refuses the same unusable bound", %{prefix: prefix} do
      write_many(prefix, 5, "a marker term")

      # Without a model this leg reports that it cannot be served, which is the
      # point: the bound is checked before the leg is attempted, so an unusable
      # one is still an error rather than a confusing failure.
      assert {:error, {:invalid_limit, 0}} =
               AgentDb.search("marker", mode: :vector, scope: prefix, top_k: 0)
    end

    test "hybrid search refuses the same unusable bound", %{prefix: prefix} do
      write_many(prefix, 5, "a marker term")

      assert {:error, {:invalid_limit, 0}} =
               AgentDb.search("marker", mode: :hybrid, scope: prefix, top_k: 0)
    end
  end
end
