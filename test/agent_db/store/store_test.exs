defmodule AgentDb.StoreTest do
  use ExUnit.Case, async: false

  alias AgentDb.Store.{Reader, SQLite, Writer}

  setup do
    # The application's own supervision tree is already running (Writer/Reader
    # are registered globally by name). Stop it for the duration of this test
    # so we can start private instances against a temp DB.
    case Process.whereis(Writer) do
      nil -> :ok
      _pid -> :ok
    end

    sup_pid = Process.whereis(AgentDb.Supervisor)

    if sup_pid do
      # Restart the real application children against our own temp path later;
      # for these tests we exercise the real tree and point Config at a temp dir.
      Supervisor.stop(AgentDb.Supervisor)
    end

    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    path = Path.join(AgentDb.Config.data_dir(), "agent_db.db")

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)

      case File.dir?(Path.dirname(path)) do
        true -> File.rm_rf(Path.dirname(path))
        false -> :ok
      end
    end)

    {:ok, path: path}
  end

  test "writes serialize through the writer and are visible to readers" do
    now = System.system_time(:millisecond)

    result =
      Writer.call(fn conn ->
        SQLite.exec_write(
          conn,
          "INSERT INTO nodes (uri, parent_uri, name, kind, content, created_at, updated_at) VALUES (?1, NULL, 'r', 'dir', NULL, ?2, ?2)",
          ["viking://", now]
        )
      end)

    assert :ok = result

    assert {:ok, [[1]]} =
             Reader.read(fn conn ->
               SQLite.query(conn, "SELECT COUNT(*) FROM nodes WHERE uri = ?", ["viking://"])
             end)
  end

  test "concurrent reads do not block each other" do
    parent = self()

    tasks =
      for i <- 1..6 do
        Task.async(fn ->
          result =
            Reader.read(fn conn ->
              SQLite.query(conn, "SELECT COUNT(*) FROM nodes")
            end)

          send(parent, {:done, i})
          {i, result}
        end)
      end

    # All six tasks share 3 reader connections and complete without deadlock.
    results = Task.await_many(tasks, 5_000)
    assert length(results) == 6
    assert Enum.all?(results, &match?({_, {:ok, [[_]]}}, &1))

    # all six completed while sharing 3 connections
    for _ <- 1..6, do: assert_receive({:done, _}, 5_000)
  end

  test "serialized writes: interleaved writer calls see each other's effects" do
    parent = self()

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          res =
            Writer.call(fn conn ->
              SQLite.exec_write(conn, "INSERT INTO sessions (id, created_at) VALUES (?1, ?2)", [
                "s#{i}",
                i
              ])
            end)

          send(parent, {:wrote, i})
          res
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 5_000), &(&1 == :ok))

    total =
      Reader.read(fn conn ->
        SQLite.query(conn, "SELECT COUNT(*) FROM sessions")
      end)

    assert {:ok, [[10]]} = total
  end

  defp temp_path, do: AgentDb.Config.test_data_dir()

  # Restarts AgentDb.Application's supervision tree with the current env.
  defp restart_app do
    :ok = Application.stop(:agent_db)

    case Application.ensure_all_started(:agent_db) do
      {:ok, _} -> :ok
      other -> flunk("failed to restart app: #{inspect(other)}")
    end
  end
end
