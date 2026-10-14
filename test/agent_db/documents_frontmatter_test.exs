defmodule AgentDb.DocumentsFrontmatterTest do
  use ExUnit.Case, async: false

  alias AgentDb.Cache

  @skill_content """
  ---
  name: easy-rpc
  description: Guidance for wrapping remote procedure calls as local Elixir functions using EasyRpc.
  ---

  # easy-rpc

  Body content for the skill goes here.
  """

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  describe "frontmatter-aware fallbacks" do
    test "skill L0 fallback uses frontmatter identity, not the delimiter" do
      uri = write("skill-l0", @skill_content)

      assert {:ok, abstract} = AgentDb.abstract(uri)
      assert abstract != "---"
      assert abstract =~ "easy-rpc"
      assert abstract =~ "Guidance for wrapping remote procedure calls"
    end

    test "skill L1 fallback skips raw frontmatter" do
      uri = write("skill-l1", @skill_content)

      assert {:ok, overview} = AgentDb.overview(uri)
      refute overview =~ "name:"
      refute overview =~ "description:"
      assert overview =~ "Body content"
    end

    test "name alone is the L0 fallback" do
      uri = write("name-only", "---\nname: solo\n---\n\nbody\n")

      assert {:ok, "solo"} = AgentDb.abstract(uri)
    end

    test "description alone is the L0 fallback" do
      uri = write("desc-only", "---\ndescription: just a description\n---\n\nbody\n")

      assert {:ok, "just a description"} = AgentDb.abstract(uri)
    end

    test "quoted values are unquoted in the identity" do
      uri =
        write("quoted", "---\nname: \"quoted name\"\ndescription: 'quoted desc'\n---\n\nbody\n")

      assert {:ok, "quoted name — quoted desc"} = AgentDb.abstract(uri)
    end

    test "a quote of a different kind is left alone" do
      uri = write("mixed-quote", "---\nname: \"unbalanced\n---\n\nbody\n")

      assert {:ok, "\"unbalanced"} = AgentDb.abstract(uri)
    end

    test "an empty value takes the folded continuation line" do
      uri =
        write("folded", "---\nname: folded\ndescription:\n  continued description\n---\n\nbody\n")

      assert {:ok, "folded — continued description"} = AgentDb.abstract(uri)
    end

    test "CRLF line endings and a BOM are tolerated" do
      uri =
        write(
          "crlf-bom",
          "\uFEFF---\r\nname: rpc\r\ndescription: does rpc\r\n---\r\n\r\nBody\r\n"
        )

      assert {:ok, "rpc — does rpc"} = AgentDb.abstract(uri)
      assert {:ok, overview} = AgentDb.overview(uri)
      assert overview =~ "Body"
      refute overview =~ "name:"
    end

    test "an unclosed delimiter is treated as plain content" do
      uri = write("unclosed", "---\nname: never closed\nbody line\n")

      assert {:ok, "---"} = AgentDb.abstract(uri)
      assert {:ok, overview} = AgentDb.overview(uri)
      assert overview == String.slice("---\nname: never closed\nbody line\n", 0, 280)
    end

    test "a mid-document separator is not frontmatter" do
      uri = write("mid-separator", "intro line\n\n---\n\nmore\n")

      assert {:ok, "intro line"} = AgentDb.abstract(uri)
      assert {:ok, "intro line\n\n---\n\nmore\n"} = AgentDb.overview(uri)
    end

    test "a delimiter block with no key-value line is plain content" do
      uri = write("keyless", "---\njust prose\n---\n\nbody\n")

      assert {:ok, "---"} = AgentDb.abstract(uri)
    end

    test "an empty body after frontmatter yields an empty L1 but keeps L0" do
      uri = write("empty-body", "---\nname: headeronly\n---\n")

      assert {:ok, "headeronly"} = AgentDb.abstract(uri)
      assert {:ok, ""} = AgentDb.overview(uri)
    end

    test "the identity is bounded to 280 characters" do
      long = String.duplicate("d", 400)
      uri = write("bounded", "---\nname: n\ndescription: #{long}\n---\n\nbody\n")

      assert {:ok, abstract} = AgentDb.abstract(uri)
      assert String.length(abstract) == 280
    end

    test "a plain document without frontmatter is unchanged" do
      content = "\n  second line is first non-empty \nbody"
      uri = write("plain", content)

      assert {:ok, "second line is first non-empty"} = AgentDb.abstract(uri)
      assert {:ok, ^content} = AgentDb.overview(uri)
    end
  end

  defp write(name, content) do
    uri = "viking://resources/frontmatter/#{name}.md"
    assert :ok = AgentDb.write(uri, content)
    uri
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  describe "a fallback abstract carries no markup marker" do
    test "a leading heading marker is stripped" do
      uri = write("heading", "## Storage layout\n\nbody\n")

      assert {:ok, "Storage layout"} = AgentDb.abstract(uri)
    end

    test "a leading blockquote marker is stripped" do
      uri = write("quote", "> a quoted first line\n\nbody\n")

      assert {:ok, "a quoted first line"} = AgentDb.abstract(uri)
    end

    test "a leading list bullet is stripped" do
      uri = write("bullet", "- a bulleted first line\n\nbody\n")

      assert {:ok, "a bulleted first line"} = AgentDb.abstract(uri)
    end

    test "a plain first line is returned unchanged" do
      uri = write("plain", "A plain first line\n\nbody\n")

      assert {:ok, "A plain first line"} = AgentDb.abstract(uri)
    end

    test "a line of only markers keeps its text" do
      # Nothing remains once the marker is gone, so the line is left as written
      # rather than becoming an abstract that says nothing.
      uri = write("markers-only", "###\n\nbody\n")

      assert {:ok, abstract} = AgentDb.abstract(uri)
      assert abstract =~ "#"
    end

    test "a marker inside the body is not stripped" do
      uri = write("inner-marker", "first line\n\n- a bullet in the body\n")

      assert {:ok, "first line"} = AgentDb.abstract(uri)
    end
  end

  describe "a fallback overview truncates on a word boundary" do
    test "a long body stops at a word, not mid-word" do
      # Each word is 5 characters plus a space, so a raw 280-character slice
      # would always land inside one.
      body = String.duplicate("alpha ", 80)
      uri = write("long-body", body)

      assert {:ok, overview} = AgentDb.overview(uri)
      assert String.length(overview) <= 280
      assert String.ends_with?(overview, "alpha")
      assert overview =~ ~r/^alpha( alpha)*$/
    end

    test "a short body is returned whole" do
      uri = write("short-body", "a short body\n")

      assert {:ok, overview} = AgentDb.overview(uri)

      # Nothing was trimmed, so the whole body is there -- including the
      # trailing newline the bound never had cause to touch.
      assert overview == "a short body\n"
    end

    test "the bound is unchanged" do
      body = String.duplicate("x", 1_000)
      uri = write("wide-body", body)

      assert {:ok, overview} = AgentDb.overview(uri)
      assert String.length(overview) == 280
    end
  end
end
