defmodule AgentDb.NavigationTest do
  @moduledoc """
  In-process navigation: bounded path discovery and literal content inspection.

  `find/2` locates paths by name and `grep/2` inspects matching source
  lines, both scoped to a subtree and bounded. Ranked `search/2` keeps its
  existing content-and-summary behaviour.
  """
  use ExUnit.Case, async: false

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  describe "find/2" do
    test "discovers paths within a subtree, ordered, without content" do
      :ok = AgentDb.write("viking://resources/nav/project/auth.md", "a")
      :ok = AgentDb.write("viking://resources/nav/project/nested/auth-helper.md", "b")
      :ok = AgentDb.write("viking://resources/nav/other/auth-outside.md", "c")

      assert {:ok, hits} = AgentDb.find("auth", scope: "viking://resources/nav/project")

      assert Enum.map(hits, & &1.uri) == [
               "viking://resources/nav/project/auth.md",
               "viking://resources/nav/project/nested/auth-helper.md"
             ]

      for hit <- hits do
        assert %{uri: _, name: _, kind: _} = hit
        refute Map.has_key?(hit, :content)
      end
    end

    test "scope is exact-URI-or-descendant" do
      :ok = AgentDb.write("viking://resources/navproj/auth.md", "in")
      :ok = AgentDb.write("viking://resources/navproj-old/auth.md", "sibling")

      assert {:ok, hits} = AgentDb.find("auth", scope: "viking://resources/navproj")
      assert Enum.map(hits, & &1.uri) == ["viking://resources/navproj/auth.md"]
    end

    test "treats wildcard characters literally" do
      :ok = AgentDb.write("viking://resources/lit/100%.md", "a")
      :ok = AgentDb.write("viking://resources/lit/normal.md", "b")

      assert {:ok, [%{uri: "viking://resources/lit/100%.md"}]} = AgentDb.find("%")
      assert {:ok, []} = AgentDb.find("\\")
    end

    test "rejects empty and oversized queries" do
      assert {:error, {:invalid_query, ""}} = AgentDb.find("")
      assert {:error, {:invalid_query, _}} = AgentDb.find(String.duplicate("x", 257))
      assert {:error, {:invalid_query, _}} = AgentDb.find(:not_a_string)
    end

    test "rejects malformed and missing scopes" do
      :ok = AgentDb.write("viking://resources/nav/a.md", "x")

      assert {:error, :invalid_uri} = AgentDb.find("a", scope: "http://elsewhere/x")
      assert {:error, :invalid_uri} = AgentDb.find("a", scope: "viking://a/../b")
      assert {:error, :not_found} = AgentDb.find("a", scope: "viking://resources/nav/missing")
    end

    test "rejects invalid limits and bounds results" do
      :ok = AgentDb.write("viking://resources/bound/c.md", "x")
      :ok = AgentDb.write("viking://resources/bound/b.md", "x")
      :ok = AgentDb.write("viking://resources/bound/a.md", "x")

      assert {:error, {:invalid_limit, 0}} = AgentDb.find("bound", limit: 0)
      assert {:error, {:invalid_limit, 201}} = AgentDb.find("bound", limit: 201)
      assert {:error, {:invalid_limit, _}} = AgentDb.find("bound", limit: "10")

      assert {:ok, hits} = AgentDb.find("bound", limit: 2)
      assert length(hits) == 2
    end
  end

  describe "grep/2" do
    test "returns matching lines with numbers and bounded excerpts" do
      :ok =
        AgentDb.write(
          "viking://resources/grep/a.md",
          "first line\nsecond needle here\nthird\nneedle again"
        )

      assert {:ok, hits} = AgentDb.find("a.md", scope: "viking://resources/grep")
      assert length(hits) >= 1

      assert {:ok, [first, second]} =
               AgentDb.grep("needle", scope: "viking://resources/grep/a.md")

      assert first.line_number == 2
      assert second.line_number == 4

      for hit <- [first, second] do
        assert String.contains?(String.downcase(hit.excerpt), "needle")
        assert String.length(hit.excerpt) <= 280
      end
    end

    test "searches L2 content only" do
      :ok =
        AgentDb.write("viking://resources/grep-layers.md", "plain body",
          abstract: "unique-abstract-needle",
          overview: "unique-overview-needle"
        )

      assert {:ok, []} = AgentDb.grep("unique-abstract-needle")
      assert {:ok, []} = AgentDb.grep("unique-overview-needle")
      assert {:ok, [_]} = AgentDb.grep("plain body")
    end

    test "treats special characters literally and stays bounded" do
      :ok = AgentDb.write("viking://resources/special.md", "100% sure\na.*b literal\nnormal")

      assert {:ok, [_]} = AgentDb.grep("%")
      assert {:ok, [_]} = AgentDb.grep(".*")
      assert {:ok, []} = AgentDb.grep("no-such-grep-needle-xyz")

      long = String.duplicate("x", 200) <> "needle" <> String.duplicate("y", 300)
      :ok = AgentDb.write("viking://resources/long.md", long)

      assert {:ok, [hit]} = AgentDb.grep("needle", scope: "viking://resources/long.md")
      assert String.contains?(hit.excerpt, "needle")
      assert String.length(hit.excerpt) <= 280
    end

    test "rejects bad queries, scopes, and limits" do
      assert {:error, {:invalid_query, ""}} = AgentDb.grep("")
      assert {:error, {:invalid_query, _}} = AgentDb.grep(String.duplicate("x", 300))
      assert {:error, :invalid_uri} = AgentDb.grep("x", scope: "not-a-uri")
      assert {:error, :not_found} = AgentDb.grep("x", scope: "viking://resources/missing-scope")
      assert {:error, {:invalid_limit, 0}} = AgentDb.grep("x", limit: 0)
      assert {:error, {:invalid_limit, 500}} = AgentDb.grep("x", limit: 500)
    end

    test "bounds results in URI then line order" do
      :ok = AgentDb.write("viking://resources/many/b.md", "needle one\nneedle two\nneedle three")
      :ok = AgentDb.write("viking://resources/many/a.md", "needle zero")

      assert {:ok, hits} = AgentDb.grep("needle", scope: "viking://resources/many", limit: 2)
      assert length(hits) == 2
      assert hd(hits).uri == "viking://resources/many/a.md"
    end
  end

  describe "search/2 is unchanged" do
    test "still matches abstracts and overviews" do
      :ok =
        AgentDb.write("viking://resources/compat.md", "body content",
          abstract: "compat-abstract",
          overview: "compat-overview"
        )

      assert {:ok, [_]} = AgentDb.search("compat-abstract")
      assert {:ok, [_]} = AgentDb.search("compat-overview")
      assert {:ok, []} = AgentDb.grep("compat-abstract")
    end
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
