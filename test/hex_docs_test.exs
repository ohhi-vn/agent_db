defmodule AgentDb.HexDocsTest do
  use ExUnit.Case, async: false

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "discovers locked packages offline" do
    dir = Path.join(System.tmp_dir!(), "hex_lock_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    lock = Path.join(dir, "mix.lock")

    File.write!(lock, """
    %{
      "phoenix" => {:hex, :phoenix, "1.8.0", "abc", [:mix], [], "hexpm", "abc"},
      "ecto" => {:hex, :ecto, "3.12.0", "def", [:mix], [], "hexpm", "def"}
    }
    """)

    assert {:ok, pkgs} = AgentDb.HexDocs.discover(lock)
    assert %{"phoenix" => "1.8.0", "ecto" => "3.12.0"} = Map.new(pkgs, &{&1.package, &1.version})

    File.rm_rf!(dir)
  end

  test "missing lockfile reports empty Hex context" do
    assert {:ok, []} = AgentDb.HexDocs.discover("/nonexistent/mix.lock")
  end

  test "locked version outranks other versions offline" do
    for ver <- ["1.7.0", "1.8.0", "1.9.0"] do
      :ok = AgentDb.write("viking://resources/hex/phoenix/#{ver}/README.md", "Phoenix authentication #{ver}")
    end

    locked = %{"phoenix" => "1.8.0"}

    {:ok, results} = AgentDb.search("Phoenix authentication", mode: :keyword, scope: "viking://resources/hex")
    ranked = AgentDb.HexDocs.rank(results, locked)

    assert hd(ranked).uri =~ "phoenix/1.8.0"
    assert Enum.all?(ranked, &(&1.uri =~ "phoenix/"))
  end

  test "lock upgrade adds a version without losing the old one" do
    :ok = AgentDb.write("viking://resources/hex/phoenix/1.8.0/README.md", "phoenix old docs")
    :ok = AgentDb.write("viking://resources/hex/phoenix/1.8.1/README.md", "phoenix new docs")

    assert {:ok, "phoenix old docs"} = AgentDb.read("viking://resources/hex/phoenix/1.8.0/README.md")
    assert {:ok, "phoenix new docs"} = AgentDb.read("viking://resources/hex/phoenix/1.8.1/README.md")

    {:ok, results} = AgentDb.search("phoenix", mode: :keyword, scope: "viking://resources/hex")
    ranked = AgentDb.HexDocs.rank(results, %{"phoenix" => "1.8.1"})
    assert hd(ranked).uri =~ "1.8.1"
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
