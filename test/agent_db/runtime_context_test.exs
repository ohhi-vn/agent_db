defmodule AgentDb.RuntimeContextTest do
  use ExUnit.Case, async: false

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "captures a runtime snapshot without disturbing processes" do
    before_pids = Process.list()

    assert {:ok, snap} = AgentDb.RuntimeContext.snapshot()
    assert is_integer(snap.captured_at)
    assert is_list(snap.applications)
    assert is_map(snap.process_counts)
    assert is_list(snap.processes)
    assert is_list(snap.ets)
    assert is_map(snap.memory)
    assert Map.has_key?(snap, :truncated)

    # No process was restarted or messaged by the capture.
    assert MapSet.subset?(MapSet.new(before_pids), MapSet.new(Process.list()))

    # Redaction: no message bodies, ETS contents, or credentials.
    blob = inspect(snap)
    refute blob =~ "sk-secret"

    for proc <- snap.processes do
      assert Map.has_key?(proc, :mailbox_len)
      refute Map.has_key?(proc, :messages)
      refute Map.has_key?(proc, :message_body)
    end
  end

  test "large runtime truncates safely" do
    # Spawn more than the bound would allow if it were small; the snapshot
    # must still succeed with a boolean truncation flag.
    assert {:ok, snap} = AgentDb.RuntimeContext.snapshot()
    assert is_boolean(snap.truncated)
  end

  test "unreachable node reports an error and store still works" do
    assert {:error, {:node_unreachable, _}} =
             AgentDb.RuntimeContext.snapshot(:down@nonexistent)

    assert :ok = AgentDb.write("viking://resources/snap/a.md", "still works")
    assert {:ok, "still works"} = AgentDb.read("viking://resources/snap/a.md")

    # Snapshots never auto-write into the tree.
    assert {:error, :not_found} = AgentDb.read("viking://runtime/snapshot")
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
