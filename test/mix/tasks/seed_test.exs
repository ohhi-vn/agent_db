defmodule Mix.Tasks.AgentDb.SeedTest do
  @moduledoc """
  The seed command, driven the way an operator would drive it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentDb.Cache
  alias Mix.Tasks.AgentDb.Seed

  @prefix "viking://resources/demo"

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "seeds and reports counts" do
    output = run([])

    assert output =~ "seeded"
    assert output =~ "5 documents"
    assert output =~ "5 memories"
    assert output =~ @prefix
    assert {:ok, _} = AgentDb.read(@prefix <> "/readme.md")
  end

  test "--json prints a machine-readable result" do
    output = run(["--json"])
    decoded = Jason.decode!(output)

    assert decoded["prefix"] == @prefix
    assert decoded["documents"] == 5
    assert decoded["memories"] == 5
    assert decoded["sessions"] == 1
    assert decoded["skills"] == 1
    assert decoded["indexed"] == 2
  end

  test "a non-empty store fails without writing seed data" do
    :ok = AgentDb.write("viking://resources/real.md", "real data")

    assert_raise Mix.Error, ~r/store_not_empty/, fn -> run([]) end
    assert {:error, :not_found} = AgentDb.read(@prefix <> "/readme.md")
  end

  test "--force merges while outside data survives" do
    :ok = AgentDb.write("viking://resources/real.md", "real data")

    assert run(["--force"]) =~ "seeded"
    assert {:ok, "real data"} = AgentDb.read("viking://resources/real.md")
  end

  test "--clean resets only the seed scope" do
    assert run([]) =~ "seeded"
    :ok = AgentDb.write("viking://resources/real.md", "real data")
    :ok = AgentDb.write(@prefix <> "/extra.md", "stale extra")

    assert run(["--clean"]) =~ "seeded"
    assert {:ok, "real data"} = AgentDb.read("viking://resources/real.md")
    assert {:error, :not_found} = AgentDb.read(@prefix <> "/extra.md")
  end

  test "--prefix isolates the dataset" do
    output = run(["--prefix", "viking://resources/custom", "--json"])
    decoded = Jason.decode!(output)

    assert decoded["prefix"] == "viking://resources/custom"
    assert {:ok, _} = AgentDb.read("viking://resources/custom/readme.md")
    assert {:error, :not_found} = AgentDb.read(@prefix <> "/readme.md")
  end

  test "--force and --clean cannot be combined" do
    assert_raise Mix.Error, ~r/cannot be combined/, fn ->
      run(["--force", "--clean"])
    end
  end

  describe "the help it prints" do
    test "names the flags, the guards, and the rollback" do
      {:docs_v1, _, _, _, %{"en" => help}, _, _} = Code.fetch_docs(Seed)

      assert help =~ "mix agent_db.seed"
      assert help =~ "--prefix"
      assert help =~ "--force"
      assert help =~ "--clean"
      assert help =~ "--allow-prod"
      assert help =~ "--json"
      assert help =~ "non-empty store is refused"
      assert help =~ "production"
      assert help =~ "Rollback"
    end

    test "mix help agent_db.seed renders" do
      output =
        capture_io(fn -> Mix.Task.run("help", ["agent_db.seed"]) end)
        |> String.replace(~r/\e\[[0-9;]*m/, "")

      assert output =~ "mix agent_db.seed"
    end
  end

  defp run(argv) do
    capture_io(fn -> apply(Seed, :run, [argv]) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
