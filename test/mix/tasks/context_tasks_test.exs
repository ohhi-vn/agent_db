defmodule Mix.Tasks.ContextTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "index, search, tree, and doctor reuse the facade" do
    dir = Path.join(System.tmp_dir!(), "mix_ctx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.ex"), "defmodule MixCtx.A do def go, do: :ok end")

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Index.run(["--project", "mixctx", "--dir", dir, "--no-compile"])
      end)

    assert out =~ "indexed 1 files"

    :ok = AgentDb.write("viking://resources/mixctx-search/a.md", "mix search hello")

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Search.run(["hello", "--mode", "keyword", "--no-compile"])
      end)

    assert out =~ "viking://resources/mixctx-search/a.md"

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Tree.run(["viking://resources/mixctx-search", "--no-compile"])
      end)

    assert out =~ "mixctx-search"

    out =
      capture_io(fn ->
        Mix.Tasks.AgentDb.Doctor.run(["--no-compile"])
      end)

    assert out =~ "db:"
    assert out =~ "provider:"
    assert out =~ "pubsub:"

    File.rm_rf!(dir)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
