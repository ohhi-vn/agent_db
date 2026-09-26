defmodule AgentDb.Store.SQLiteTest do
  use ExUnit.Case, async: false

  alias AgentDb.Store.SQLite

  test "ensure_schema is idempotent on a temp-file DB" do
    path = temp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, conn} = SQLite.open(path)
    assert :ok = SQLite.ensure_schema(conn)
    assert :ok = SQLite.ensure_schema(conn)

    {:ok, rows} =
      SQLite.query(conn, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")

    tables = Enum.map(rows, &hd/1)
    assert "nodes" in tables
    assert "sessions" in tables
    assert "session_messages" in tables
    assert "commit_meta" in tables

    # WAL mode + foreign keys active
    {:ok, [[journal]]} = SQLite.query(conn, "PRAGMA journal_mode")
    assert journal == "wal"
    {:ok, [[fk]]} = SQLite.query(conn, "PRAGMA foreign_keys")
    assert fk == 1

    # basic write/read round trip
    now = System.system_time(:millisecond)

    assert :ok =
             SQLite.exec_write(
               conn,
               "INSERT INTO nodes (uri, parent_uri, name, kind, content, created_at, updated_at) VALUES (?1, NULL, 'root', 'dir', NULL, ?2, ?2)",
               ["viking://", now]
             )

    assert {:ok, [[^now]]} =
             SQLite.query(conn, "SELECT created_at FROM nodes WHERE uri = ?1", ["viking://"])

    :ok = SQLite.close(conn)
  end

  test "foreign key cascade deletes session messages" do
    path = temp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, conn} = SQLite.open(path)
    :ok = SQLite.ensure_schema(conn)
    now = System.system_time(:millisecond)

    :ok =
      SQLite.exec_write(conn, "INSERT INTO sessions (id, created_at) VALUES (?1, ?2)", ["s1", now])

    :ok =
      SQLite.exec_write(
        conn,
        "INSERT INTO session_messages (session_id, seq, role, content) VALUES (?1, 0, 'user', 'hi')",
        ["s1"]
      )

    assert {:ok, [[1]]} = SQLite.query(conn, "SELECT COUNT(*) FROM session_messages")
    :ok = SQLite.exec_write(conn, "DELETE FROM sessions WHERE id = ?1", ["s1"])
    assert {:ok, [[0]]} = SQLite.query(conn, "SELECT COUNT(*) FROM session_messages")

    :ok = SQLite.close(conn)
  end

  test "query_one returns nil for empty result" do
    path = temp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, conn} = SQLite.open(path)
    :ok = SQLite.ensure_schema(conn)
    assert {:ok, nil} = SQLite.query_one(conn, "SELECT uri FROM nodes WHERE uri = ?1", ["nope"])
    :ok = SQLite.close(conn)
  end

  test "migration: old schema DB upgraded with new tables" do
    path = temp_path()
    on_exit(fn -> File.rm(path) end)

    # Create old schema (without vec_nodes and job_queue)
    {:ok, conn} = SQLite.open(path)
    
    # Create old tables
    SQLite.exec_write(conn, """
      CREATE TABLE nodes (
        uri TEXT PRIMARY KEY,
        parent_uri TEXT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('doc', 'dir')),
        content TEXT,
        abstract TEXT,
        overview TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (parent_uri) REFERENCES nodes(uri) ON DELETE CASCADE
      )
    """)
    
    SQLite.exec_write(conn, "CREATE INDEX idx_nodes_parent ON nodes(parent_uri)")
    SQLite.exec_write(conn, "CREATE INDEX idx_nodes_kind ON nodes(kind)")
    
    SQLite.exec_write(conn, """
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL
      )
    """)
    
    SQLite.exec_write(conn, """
      CREATE TABLE session_messages (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        PRIMARY KEY (session_id, seq),
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    """)
    
    SQLite.exec_write(conn, """
      CREATE TABLE commit_meta (
        session_id TEXT NOT NULL,
        destination_uri TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        committed_at INTEGER NOT NULL,
        PRIMARY KEY (session_id, destination_uri),
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    """)
    
    :ok = SQLite.close(conn)
    
    # Reopen and run ensure_schema - should add new tables
    {:ok, conn} = SQLite.open(path)
    assert :ok = SQLite.ensure_schema(conn)
    
    # Verify new tables exist (job_queue should always be created, vec_nodes only if sqlite-vec available)
    {:ok, rows} = SQLite.query(conn, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    tables = Enum.map(rows, &hd/1)
    assert "job_queue" in tables
    
    # Verify indexes
    {:ok, idx_rows} = SQLite.query(conn, "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name")
    idx_names = Enum.map(idx_rows, &hd/1)
    assert "idx_job_queue_status_sched" in idx_names
    
    :ok = SQLite.close(conn)
  end

  test "ensure_schema is idempotent with all tables" do
    path = temp_path()
    on_exit(fn -> File.rm(path) end)

    {:ok, conn} = SQLite.open(path)
    assert :ok = SQLite.ensure_schema(conn)
    assert :ok = SQLite.ensure_schema(conn)
    assert :ok = SQLite.ensure_schema(conn)

    {:ok, rows} =
      SQLite.query(conn, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")

    tables = Enum.map(rows, &hd/1)
    assert "nodes" in tables
    assert "sessions" in tables
    assert "session_messages" in tables
    assert "commit_meta" in tables
    assert "job_queue" in tables
    # vec_nodes only if sqlite-vec extension available
    if "vec_nodes" in tables do
      assert "vec_nodes" in tables
    end

    :ok = SQLite.close(conn)
  end

  describe "vec_available?/1" do
    test "reports false when the sqlite-vec extension is not loaded" do
      path = temp_path()
      on_exit(fn -> File.rm(path) end)

      {:ok, conn} = SQLite.open(path)
      :ok = SQLite.ensure_schema(conn)

      # vec_nodes is only created when the extension loads, so availability and
      # the table's existence must agree.
      assert SQLite.vec_available?(conn) == ("vec_nodes" in table_names(conn))

      :ok = SQLite.close(conn)
    end
  end

  describe "transaction/2" do
    setup do
      path = temp_path()
      on_exit(fn -> File.rm(path) end)

      {:ok, conn} = SQLite.open(path)
      :ok = SQLite.ensure_schema(conn)
      %{conn: conn}
    end

    test "commits when the fun returns :ok or {:ok, _}", %{conn: conn} do
      assert :ok = SQLite.transaction(conn, fn c -> insert_node(c, "viking://a") end)
      assert {:ok, [1]} = count_nodes(conn, "viking://a")

      assert {:ok, :inserted} =
               SQLite.transaction(conn, fn c ->
                 with :ok <- insert_node(c, "viking://b"), do: {:ok, :inserted}
               end)

      assert {:ok, [1]} = count_nodes(conn, "viking://b")
    end

    test "rolls back and propagates the error when the fun fails", %{conn: conn} do
      assert {:error, :boom} =
               SQLite.transaction(conn, fn c ->
                 :ok = insert_node(c, "viking://a")
                 {:error, :boom}
               end)

      assert {:ok, [0]} = count_nodes(conn, "viking://a")

      # The connection must still be usable, and not left inside a transaction.
      assert :ok = SQLite.transaction(conn, fn c -> insert_node(c, "viking://c") end)
      assert {:ok, [1]} = count_nodes(conn, "viking://c")
    end

    test "rolls back when the fun raises, leaving the connection usable", %{conn: conn} do
      assert_raise RuntimeError, "kaboom", fn ->
        SQLite.transaction(conn, fn c ->
          :ok = insert_node(c, "viking://a")
          raise "kaboom"
        end)
      end

      # No manual ROLLBACK: the helper must have unwound the transaction itself,
      # otherwise the Writer's connection stays poisoned for every later write.
      assert {:ok, [0]} = count_nodes(conn, "viking://a")

      assert :ok = SQLite.transaction(conn, fn c -> insert_node(c, "viking://c") end)
      assert {:ok, [1]} = count_nodes(conn, "viking://c")
    end
  end

  defp insert_node(conn, uri) do
    now = System.system_time(:millisecond)

    SQLite.exec_write(
      conn,
      "INSERT INTO nodes (uri, parent_uri, name, kind, content, created_at, updated_at) VALUES (?1, NULL, 'n', 'doc', 'c', ?2, ?2)",
      [uri, now]
    )
  end

  defp count_nodes(conn, uri) do
    SQLite.query_one(conn, "SELECT COUNT(*) FROM nodes WHERE uri = ?1", [uri])
  end

  defp table_names(conn) do
    {:ok, rows} =
      SQLite.query(conn, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")

    Enum.map(rows, &hd/1)
  end

  defp temp_path,
    do: Path.join(System.tmp_dir!(), "agent_db_test_#{:erlang.unique_integer([:positive])}.db")
end
