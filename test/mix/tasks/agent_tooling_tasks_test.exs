defmodule Mix.Tasks.AgentToolingTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "abstract and overview read one layer each, as JSON and as text" do
    uri = "viking://resources/cli-tasks/layerable.md"

    :ok =
      AgentDb.write(uri, "a body long enough to measure",
        abstract: "a supplied abstract",
        overview: "a supplied overview"
      )

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Abstract.run([uri, "--json", "--no-compile"])
      end)

    assert %{"uri" => ^uri, "abstract" => "a supplied abstract"} = Jason.decode!(out)

    # Without --json the layer is printed alone, so a shell can use it directly.
    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Overview.run([uri, "--no-compile"])
      end)

    assert String.trim(out) == "a supplied overview"
  end

  test "a layer read on a missing document exits non-zero with the reason" do
    assert_raise Mix.Error, ~r/not_found/, fn ->
      capture_io(fn ->
        Mix.Tasks.AgentDb.Abstract.run(["viking://resources/cli-tasks/absent.md", "--no-compile"])
      end)
    end

    assert_raise Mix.Error, ~r/not_found/, fn ->
      capture_io(fn ->
        Mix.Tasks.AgentDb.Overview.run(["viking://resources/cli-tasks/absent.md", "--no-compile"])
      end)
    end
  end

  test "read, find, grep, and recall reach the facade" do
    :ok = AgentDb.write("viking://resources/cli-tasks/a.md", "cli tasks hello")

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Read.run(["viking://resources/cli-tasks/a.md", "--no-compile"])
      end)

    assert out =~ "cli tasks hello"

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Find.run(["cli-tasks", "--no-compile"])
      end)

    assert out =~ "viking://resources/cli-tasks/a.md"

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Grep.run(["cli tasks hello", "--no-compile"])
      end)

    assert out =~ "viking://resources/cli-tasks/a.md"

    {:ok, _} =
      AgentDb.remember("viking://user/memories/preferences/cli_tool", "prefers cli json")

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Recall.run([
          "viking://user/memories/preferences/cli_tool",
          "--no-compile"
        ])
      end)

    assert out =~ "prefers cli json"
  end

  test "--json prints parseable JSON and text stays default" do
    :ok = AgentDb.write("viking://resources/cli-json/b.md", "json content here")

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Read.run(["viking://resources/cli-json/b.md", "--json", "--no-compile"])
      end)

    assert %{"uri" => "viking://resources/cli-json/b.md", "content" => "json content here"} =
             Jason.decode!(out)

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Search.run(["json content here", "--json", "--no-compile"])
      end)

    assert [%{"uri" => "viking://resources/cli-json/b.md"} | _] = Jason.decode!(out)

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Tree.run(["viking://resources/cli-json", "--json", "--no-compile"])
      end)

    assert is_map(Jason.decode!(out))

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Find.run(["cli-json", "--json", "--no-compile"])
      end)

    assert is_list(Jason.decode!(out))

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Grep.run(["json content here", "--json", "--no-compile"])
      end)

    assert is_list(Jason.decode!(out))

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Doctor.run(["--json", "--no-compile"])
      end)

    assert %{"db" => _, "pubsub" => _} = Jason.decode!(out)

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Tree.run(["viking://resources/cli-json", "--no-compile"])
      end)

    assert out =~ "cli-json"
    refute match?({:ok, _}, Jason.decode(out))
  end

  test "recall of a malformed scope exits non-zero with the reason" do
    assert_raise Mix.Error, ~r/invalid_uri/, fn ->
      capture_io(fn ->
        Mix.Tasks.AgentDb.Recall.run(["notaschi", "--no-compile"])
      end)
    end
  end

  test "recall --type filters by type as JSON" do
    {:ok, _} =
      AgentDb.remember("viking://user/memories/preferences/cli_type", "type filter check")

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Recall.run(["--type", "preferences", "--json", "--no-compile"])
      end)

    memories = Jason.decode!(out)
    assert Enum.any?(memories, &(&1["value"] == "type filter check"))
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
