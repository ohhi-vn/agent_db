defmodule Mix.Tasks.AgentDb.ImportDataTest do
  @moduledoc """
  The import command, driven the way an operator would drive it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentDb.Cache
  alias Mix.Tasks.AgentDb.ImportData

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "imports an exported archive and reports counts" do
    :ok = AgentDb.write("viking://resources/project/readme.md", "# Project")
    path = tmp("backup.tar.gz")
    assert {:ok, _} = AgentDb.export_data(path)

    restart_fresh!()

    output = run([path])

    assert output =~ "imported"
    assert output =~ "1 documents"
    assert {:ok, "# Project"} = AgentDb.read("viking://resources/project/readme.md")
  end

  test "--json prints a machine-readable result" do
    :ok = AgentDb.write("viking://resources/project/readme.md", "# Project")
    path = tmp("backup.tar")
    assert {:ok, _} = AgentDb.export_data(path)
    restart_fresh!()

    output = run([path, "--json"])
    decoded = Jason.decode!(output)

    assert decoded["documents"] == 1
  end

  test "a corrupt file fails without writing" do
    path = tmp("corrupt.tar")
    File.write!(path, :crypto.strong_rand_bytes(64))

    assert_raise Mix.Error, ~r/Import failed/, fn -> run([path]) end

    assert {:ok, []} = AgentDb.find("readme", limit: 200)
  end

  test "a missing source file fails" do
    assert_raise Mix.Error, ~r/Import failed/, fn ->
      run([tmp("no-such.tar")])
    end
  end

  test "a missing path argument fails" do
    assert_raise Mix.Error, ~r/Expected one PATH/, fn -> run([]) end
  end

  defp run(argv) do
    capture_io(fn -> apply(ImportData, :run, [argv]) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
  end

  defp tmp(name) do
    dir =
      Path.join(System.tmp_dir!(), "agent_db_import_task_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    Path.join(dir, name)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  defp restart_fresh! do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()
  end
end
