defmodule AgentDb.Store.SQLiteSchemaTest do
  @moduledoc """
  The schema the store opens its database with.

  Base tables are created with `CREATE TABLE IF NOT EXISTS`, which cannot add a
  column to a table that already exists. These tests cover the other half of that
  arrangement: a database created before a column was introduced, opened by the
  current code, has to end up in the same shape as a fresh one -- and doing so
  must not be destructive or repeatable into failure.
  """
  use ExUnit.Case, async: true

  alias AgentDb.Store.SQLite

  # A database as it looked before `last_error` existed: the base tables, but
  # the job queue without the column this version adds.
  @legacy_job_queue """
  CREATE TABLE job_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 5,
    scheduled_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
  """

  defp with_connection(fun) do
    path = AgentDb.Test.Scratch.dir("schema") <> ".db"

    {:ok, conn} = SQLite.open(path)
    on_exit(fn -> File.rm_rf(path) end)

    fun.(conn)
  end

  defp columns(conn, table) do
    {:ok, rows} = SQLite.query(conn, "PRAGMA table_info(#{table})", [])
    Enum.map(rows, fn [_cid, name | _rest] -> name end)
  end

  describe "opening an existing database" do
    test "adds a column the stored table is missing" do
      with_connection(fn conn ->
        assert :ok = SQLite.exec(conn, @legacy_job_queue)
        refute "last_error" in columns(conn, "job_queue")

        assert :ok = SQLite.ensure_schema(conn)

        assert "last_error" in columns(conn, "job_queue")
      end)
    end

    test "keeps the rows it already had" do
      with_connection(fn conn ->
        assert :ok = SQLite.exec(conn, @legacy_job_queue)

        assert :ok =
                 SQLite.exec_write(
                   conn,
                   "INSERT INTO job_queue (kind, payload, status, scheduled_at, created_at, updated_at) VALUES ('embed', '{}', 'failed', 1, 1, 1)",
                   []
                 )

        assert :ok = SQLite.ensure_schema(conn)

        # The column is additive and nullable: widening the table must not
        # rewrite the work already recorded against it.
        assert {:ok, [["embed", nil]]} =
                 SQLite.query(conn, "SELECT kind, last_error FROM job_queue", [])
      end)
    end

    test "is a no-op when run again" do
      with_connection(fn conn ->
        assert :ok = SQLite.exec(conn, @legacy_job_queue)
        assert :ok = SQLite.ensure_schema(conn)

        assert :ok = SQLite.ensure_schema(conn)
        assert :ok = SQLite.ensure_schema(conn)

        assert "last_error" in columns(conn, "job_queue")
      end)
    end

    test "a fresh database already has the column" do
      with_connection(fn conn ->
        assert :ok = SQLite.ensure_schema(conn)

        assert "last_error" in columns(conn, "job_queue")
      end)
    end
  end
end
