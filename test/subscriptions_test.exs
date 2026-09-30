defmodule AgentDb.SubscriptionsTest do
  use ExUnit.Case, async: false

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  test "subscribe to existing subtree receives writes beneath it" do
    :ok = AgentDb.write("viking://resources/sub-project/seed.md", "seed")
    assert :ok = AgentDb.subscribe("viking://resources/sub-project")

    :ok = AgentDb.write("viking://resources/sub-project/docs/api.md", "hello")

    assert_receive {:context_changed, "viking://resources/sub-project/docs/api.md", :written, v1}, 1_000
    assert is_integer(v1)

    assert :ok = AgentDb.unsubscribe("viking://resources/sub-project")
  end

  test "subscribe to missing URI watches for creation" do
    assert :ok = AgentDb.subscribe("viking://resources/future")

    :ok = AgentDb.write("viking://resources/future/readme.md", "created")

    assert_receive {:context_changed, "viking://resources/future/readme.md", :written, _}, 1_000

    assert :ok = AgentDb.unsubscribe("viking://resources/future")
  end

  test "invalid URI subscribes to nothing" do
    assert {:error, :invalid_uri} = AgentDb.subscribe("not-a-uri")
    assert {:error, :invalid_uri} = AgentDb.unsubscribe("not-a-uri")
  end

  test "scope boundary is exact" do
    assert :ok = AgentDb.subscribe("viking://resources/project")

    :ok = AgentDb.write("viking://resources/project-old/readme.md", "sibling")

    refute_receive {:context_changed, _, _, _}, 200

    assert :ok = AgentDb.unsubscribe("viking://resources/project")
  end

  test "unsubscribe from unknown scope succeeds" do
    assert :ok = AgentDb.unsubscribe("viking://resources/never-subscribed")
  end

  test "events carry no content and versions increase" do
    assert :ok = AgentDb.subscribe("viking://resources/ver")

    :ok = AgentDb.write("viking://resources/ver/a.md", "first secret content")
    assert_receive {:context_changed, "viking://resources/ver/a.md", :written, v1}, 1_000

    :ok = AgentDb.write("viking://resources/ver/a.md", "second secret content")
    assert_receive {:context_changed, "viking://resources/ver/a.md", :written, v2}, 1_000

    assert v2 > v1

    assert :ok = AgentDb.unsubscribe("viking://resources/ver")
  end

  test "removal notifies once" do
    :ok = AgentDb.write("viking://resources/rm-sub/a.md", "x")
    assert :ok = AgentDb.subscribe("viking://resources/rm-sub")

    :ok = AgentDb.rm("viking://resources/rm-sub")

    assert_receive {:context_changed, "viking://resources/rm-sub", :removed, _}, 1_000

    assert :ok = AgentDb.unsubscribe("viking://resources/rm-sub")
  end

  test "session commit notifies watchers" do
    assert :ok = AgentDb.subscribe("viking://user/u1/memories")
    {:ok, sid} = AgentDb.create_session()
    :ok = AgentDb.append_message(sid, :user, "hi")

    {:ok, dest} = AgentDb.commit_session(sid, "viking://user/u1/memories/sess-1")

    assert_receive {:context_changed, ^dest, :committed, _}, 1_000

    assert :ok = AgentDb.unsubscribe("viking://user/u1/memories")
  end

  test "restart clears subscriptions" do
    Process.flag(:trap_exit, true)
    assert :ok = AgentDb.subscribe("viking://resources/restart-scope")
    restart_app()
    Process.flag(:trap_exit, false)

    # Drain any exit messages from the restart while subscribed.
    receive do
      {:EXIT, _, _} -> :ok
    after
      0 -> :ok
    end

    receive do
      {:context_changed, _, _, _} -> flunk("pre-restart subscription survived restart")
    after
      0 -> :ok
    end

    :ok = AgentDb.write("viking://resources/restart-scope/a.md", "after restart")

    refute_receive {:context_changed, _, _, _}, 200
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
