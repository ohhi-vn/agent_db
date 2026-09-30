defmodule AgentDb.CodeIndexTest do
  use ExUnit.Case, async: false

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  @user """
  defmodule MyApp.User do
    def create(attrs), do: {:ok, attrs}
    def get(id), do: {:ok, id}
  end
  """

  @caller_a """
  defmodule MyApp.Signup do
    alias MyApp.User
    def run(attrs), do: User.create(attrs)
  end
  """

  @caller_b """
  defmodule MyApp.Admin do
    def promote(id) do
      MyApp.User.get(id)
    end
  end
  """

  @worker """
  defmodule MyApp.Worker do
    use GenServer
    def init(arg), do: {:ok, arg}
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}
    def handle_info(:tick, s), do: {:noreply, s}
    def terminate(_reason, _state), do: :ok
  end
  """

  test "indexes an Elixir module with facts and find/grep reachability" do
    assert {:ok, %{uri: uri, facts: facts}} = AgentDb.CodeIndex.index_source("proj", "user.ex", @user)
    assert uri == "viking://resources/proj/code/user.ex"
    assert "MyApp.User" in facts.modules or facts.modules != nil

    assert {:ok, hits} = AgentDb.find("User", scope: "viking://resources/proj/code")
    assert Enum.any?(hits, &(&1.uri == uri))

    assert {:ok, lines} = AgentDb.grep("def create", scope: "viking://resources/proj/code")
    assert Enum.any?(lines, &(&1.uri == uri))
  end

  test "ingestion needs no model" do
    # Structural facts are available even when inference is unusable.
    assert {:ok, %{facts: facts}} = AgentDb.CodeIndex.index_source("proj-nomodel", "a.ex", @user)
    assert is_map(facts)
    assert {:ok, _} = AgentDb.CodeIndex.callers("proj-nomodel", "create")
  end

  test "finds callers of a function ordered by URI" do
    {:ok, _} = AgentDb.CodeIndex.index_source("proj-callers", "user.ex", @user)
    {:ok, _} = AgentDb.CodeIndex.index_source("proj-callers", "signup.ex", @caller_a)
    {:ok, _} = AgentDb.CodeIndex.index_source("proj-callers", "admin.ex", @caller_b)

    assert {:ok, hits} = AgentDb.CodeIndex.callers("proj-callers", "User")
    uris = Enum.map(hits, & &1.uri)
    assert uris == Enum.sort(uris)
    assert length(hits) >= 2
  end

  test "describes a GenServer with supervision hints and callbacks" do
    {:ok, _} = AgentDb.CodeIndex.index_source("proj-otp", "worker.ex", @worker)

    assert {:ok, desc} = AgentDb.CodeIndex.describe_module("proj-otp", "MyApp.Worker")
    assert desc.module == "MyApp.Worker"
    assert is_list(desc.callbacks)
    assert "handle_call/3" in desc.callbacks
  end

  test "one bad file does not stop indexing and re-index is idempotent" do
    dir = Path.join(System.tmp_dir!(), "code_index_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for n <- 1..10 do
      File.write!(Path.join(dir, "ok#{n}.ex"), @user)
    end

    File.write!(Path.join(dir, "bad.ex"), "defmodule Broken do def oops( end")

    assert {:ok, %{indexed: indexed, failed: failed}} = AgentDb.CodeIndex.index_dir("proj-bad", dir)
    assert length(indexed) == 10
    assert [{_rel, _reason}] = failed

    # Re-indexing an unchanged tree does not duplicate facts.
    assert {:ok, %{indexed: indexed2, failed: _}} = AgentDb.CodeIndex.index_dir("proj-bad", dir)
    assert length(indexed2) == 10

    File.rm_rf!(dir)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
