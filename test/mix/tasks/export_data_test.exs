defmodule Mix.Tasks.AgentDb.ExportDataTest do
  @moduledoc """
  The export command, driven the way an operator would drive it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentDb.Cache
  alias Mix.Tasks.AgentDb.ExportData

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "exports to a tar.gz and reports counts" do
    :ok = AgentDb.write("viking://resources/project/readme.md", "# Project")
    path = tmp("backup.tar.gz")

    output = run([path])

    assert output =~ "exported"
    assert output =~ "1 documents"
    assert File.exists?(path)
  end

  test "--json prints a machine-readable result" do
    :ok = AgentDb.write("viking://resources/project/readme.md", "# Project")
    path = tmp("backup.tar")

    output = run([path, "--json"])
    decoded = Jason.decode!(output)

    assert decoded["documents"] == 1
    assert decoded["path"] == path
  end

  test "--scope limits the export" do
    :ok = AgentDb.write("viking://resources/project/a.md", "a")
    :ok = AgentDb.write("viking://resources/other.md", "b")
    path = tmp("scoped.tar")

    output = run([path, "--scope", "viking://resources/project", "--json"])
    decoded = Jason.decode!(output)

    assert decoded["documents"] == 1
    assert output =~ "documents"
  end

  test "a missing scope fails without creating a file" do
    path = tmp("missing.tar")

    assert_raise Mix.Error, ~r/does not exist/, fn ->
      run([path, "--scope", "viking://resources/nope"])
    end

    refute File.exists?(path)
  end

  test "a missing path argument fails" do
    assert_raise Mix.Error, ~r/Expected one PATH/, fn -> run([]) end
  end

  defp run(argv) do
    capture_io(fn -> apply(ExportData, :run, [argv]) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
  end

  defp tmp(name) do
    dir =
      AgentDb.Test.Scratch.dir("agent_db_export_task")

    File.mkdir_p!(dir)
    Path.join(dir, name)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
