defmodule AgentDb.Store.SQLite do
  @moduledoc false

  # Direct SQLite access via exqlite. All functions are pure wrappers over
  # Exqlite.Sqlite3 with explicit connection passing - no process ownership here.

  alias Exqlite.Sqlite3

  require Logger

  @type conn :: Exqlite.Sqlite3.db()
  @type ok_err :: :ok | {:error, term()}

  @doc "Opens a SQLite database with WAL and foreign_keys enabled. Loads sqlite-vec extension."
  @spec open(String.t()) :: {:ok, conn()} | {:error, term()}
  def open(path) do
    with {:ok, conn} <- Sqlite3.open(path),
         :ok <- exec(conn, "PRAGMA journal_mode=WAL"),
         :ok <- exec(conn, "PRAGMA foreign_keys=ON"),
         :ok <- load_vec_extension(conn) do
      {:ok, conn}
    end
  end

  # Loads the sqlite-vec extension for vector search.
  @spec load_vec_extension(conn()) :: ok_err()
  defp load_vec_extension(conn) do
    # Try to load sqlite-vec extension. This works if the extension is compiled
    # and available in the SQLite extension directory.
    case exec(conn, "SELECT vec_version()") do
      :ok ->
        :ok

      {:error, _} ->
        # Extension not loaded, try to load it
        case exec(conn, "SELECT load_extension('vec0')") do
          :ok ->
            :ok

          {:error, _} ->
            # Try alternative names
            case exec(conn, "SELECT load_extension('sqlite_vec')") do
              :ok ->
                :ok

              {:error, _} ->
                # If all fail, continue without vec - will error at runtime when used
                :ok
            end
        end
    end
  end

  @doc "Closes a SQLite connection."
  @spec close(conn()) :: :ok
  def close(conn), do: Sqlite3.close(conn)

  @doc "Rowid inserted by the most recent INSERT on this connection."
  @spec last_insert_rowid(conn()) :: {:ok, integer()} | {:error, term()}
  def last_insert_rowid(conn), do: Sqlite3.last_insert_rowid(conn)

  @doc "Runs a DDL/pragma statement."
  @spec exec(conn(), String.t()) :: ok_err()
  def exec(conn, sql), do: Sqlite3.execute(conn, sql)

  @doc "Prepares, binds, and steps a write statement; releases the statement."
  @spec exec_write(conn(), String.t(), list()) :: ok_err()
  def exec_write(conn, sql, args \\ []) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, args),
         :done <- Sqlite3.step(conn, stmt) do
      Sqlite3.release(conn, stmt)
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected_step_result, other}}
    end
  end

  @doc """
  Runs `fun.(conn)` inside an explicit transaction, committing when it returns
  `:ok` or `{:ok, _}` and rolling back otherwise. The fun's return value is
  propagated either way. If the fun raises or throws, the transaction is rolled
  back and the error is re-raised, so a failing caller cannot leave the
  connection inside an open transaction.

  This is the only place in the codebase that opens a transaction. It relies on
  `AgentDb.Store.Writer` serializing every mutation, so `BEGIN` can never
  collide with an outer transaction. Callers must not nest: a fun that itself
  calls `transaction/2` will fail with "cannot start a transaction within a
  transaction".
  """
  @spec transaction(conn(), (conn() -> term())) :: term()
  def transaction(conn, fun) do
    with :ok <- exec(conn, "BEGIN") do
      # A raising fun escapes commit_or_rollback/2, which would leave the
      # connection inside an open transaction and break every later write on
      # it. Roll back first, then let the error through unchanged.
      try do
        commit_or_rollback(conn, fun.(conn))
      rescue
        error ->
          rollback(conn)
          reraise error, __STACKTRACE__
      catch
        kind, reason ->
          rollback(conn)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp commit_or_rollback(conn, result) do
    if committable?(result) do
      case exec(conn, "COMMIT") do
        :ok ->
          result

        {:error, reason} ->
          rollback(conn)
          {:error, {:commit_failed, result, reason}}
      end
    else
      case rollback(conn) do
        :ok -> result
        {:error, reason} -> {:error, {:rollback_failed, result, reason}}
      end
    end
  end

  defp committable?(:ok), do: true
  defp committable?({:ok, _}), do: true
  defp committable?(_), do: false

  defp rollback(conn) do
    case exec(conn, "ROLLBACK") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Transaction rollback failed, connection state unknown: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  True when the sqlite-vec extension is loaded and the `vec_nodes` virtual table
  can be queried. Every `vec_nodes` statement must be guarded by this, because
  the extension is optional at runtime (see `try_create_vec_table/1`).
  """
  @spec vec_available?(conn()) :: boolean()
  def vec_available?(conn) do
    match?({:ok, _}, query(conn, "SELECT vec_version()"))
  end

  @doc "Runs a SELECT and collects all rows as lists of column values."
  @spec query(conn(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  def query(conn, sql, args \\ []) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, args),
         {:ok, rows} <- collect_rows(conn, stmt, [], Sqlite3.step(conn, stmt)) do
      Sqlite3.release(conn, stmt)
      {:ok, rows}
    else
      {:error, _} = err -> err
    end
  end

  @doc "Runs a SELECT expecting at most one row; returns {:ok, nil} when absent."
  @spec query_one(conn(), String.t(), list()) ::
          {:ok, list() | nil} | {:error, term()}
  def query_one(conn, sql, args \\ []) do
    case query(conn, sql, args) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, row}
      {:ok, [_ | _] = rows} -> {:error, {:multiple_rows, length(rows)}}
      {:error, _} = err -> err
    end
  end

  defp collect_rows(_conn, _stmt, acc, :done), do: {:ok, Enum.reverse(acc)}

  defp collect_rows(conn, stmt, acc, {:row, row}),
    do: collect_rows(conn, stmt, [row | acc], Sqlite3.step(conn, stmt))

  defp collect_rows(_conn, _stmt, _acc, {:error, _} = err), do: err

  @doc "Runs a DDL statement list idempotently (IF NOT EXISTS throughout)."
  @spec ensure_schema(conn()) :: ok_err()
  def ensure_schema(conn) do
    # First run base schema (always required)
    Enum.reduce_while(base_ddl(), :ok, fn ddl, :ok ->
      case exec(conn, ddl) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      :ok -> add_missing_columns(conn)
      {:error, _} = err -> err
    end
    |> case do
      :ok ->
        # Then try to create vec_nodes table (optional, requires sqlite-vec extension)
        try_create_vec_table(conn)
        reconcile_orphan_embeddings(conn)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # `CREATE TABLE IF NOT EXISTS` cannot add a column to a table that already
  # exists, so a database created before a column was introduced keeps its old
  # shape. Adding one is a widening of the existing table: nullable, no default,
  # no rewrite of the rows already there -- so it runs once against a live store
  # and an older store ends up with the same shape as a fresh one.
  #
  # Guarded by the table's own columns rather than by a version marker, so a
  # database that predates the marker and one that arrived with it both work.
  @added_columns [
    # The classified reason a job last failed, so an operator can see why work
    # is failing without the failure living only in a log line that has already
    # rotated away.
    {"job_queue", "last_error", "TEXT"}
  ]

  defp add_missing_columns(conn) do
    Enum.reduce_while(@added_columns, :ok, fn {table, column, definition}, :ok ->
      case column_present?(conn, table, column) do
        {:ok, true} ->
          {:cont, :ok}

        {:ok, false} ->
          case exec(conn, "ALTER TABLE #{table} ADD COLUMN #{column} #{definition}") do
            :ok ->
              {:cont, :ok}

            {:error, _} = err ->
              {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # PRAGMA table_info returns one row per column as
  # {cid, name, type, notnull, dflt_value, pk}.
  defp column_present?(conn, table, column) do
    case query(conn, "PRAGMA table_info(#{table})", []) do
      {:ok, rows} -> {:ok, Enum.any?(rows, fn [_cid, name | _rest] -> name == column end)}
      {:error, _} = err -> err
    end
  end

  # Releases vec_nodes rows left behind by removals that predate the purge in
  # Nodes.purge_uri_state/2. Such rows are already invisible to search (the
  # query joins nodes), so this is about reclaiming storage and about not
  # letting a node recreated at an old deleted URI inherit a stale embedding.
  # Guarded by an existence check so a clean or large vec_nodes is not scanned
  # on every boot.
  defp reconcile_orphan_embeddings(conn) do
    if vec_available?(conn) do
      case query_one(
             conn,
             "SELECT EXISTS(SELECT 1 FROM vec_nodes v LEFT JOIN nodes n ON n.uri = v.uri WHERE n.uri IS NULL)"
           ) do
        {:ok, [1]} ->
          case exec_write(
                 conn,
                 "DELETE FROM vec_nodes WHERE uri IN (SELECT v.uri FROM vec_nodes v LEFT JOIN nodes n ON n.uri = v.uri WHERE n.uri IS NULL)"
               ) do
            :ok ->
              Logger.info("Reclaimed orphaned vec_nodes rows for removed URIs")
              :ok

            {:error, reason} ->
              Logger.warning("Could not reclaim orphaned vec_nodes rows: #{inspect(reason)}")
              :ok
          end

        {:ok, [0]} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not check for orphaned vec_nodes rows: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp base_ddl do
    [
      """
      CREATE TABLE IF NOT EXISTS nodes (
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
      """,
      "CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_uri)",
      "CREATE INDEX IF NOT EXISTS idx_nodes_kind ON nodes(kind)",
      """
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS session_messages (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        PRIMARY KEY (session_id, seq),
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS commit_meta (
        session_id TEXT NOT NULL,
        destination_uri TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        committed_at INTEGER NOT NULL,
        PRIMARY KEY (session_id, destination_uri),
        FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS memory_meta (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uri TEXT NOT NULL,
        value TEXT NOT NULL,
        confidence REAL NOT NULL,
        source TEXT,
        status TEXT NOT NULL CHECK (status IN ('active', 'superseded')),
        supersedes INTEGER REFERENCES memory_meta(id),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (uri) REFERENCES nodes(uri) ON DELETE CASCADE
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_memory_meta_uri_status ON memory_meta(uri, status)",
      "CREATE INDEX IF NOT EXISTS idx_memory_meta_status ON memory_meta(status)",
      """
      CREATE TABLE IF NOT EXISTS job_queue (
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
      """,
      "CREATE INDEX IF NOT EXISTS idx_job_queue_status_sched ON job_queue(status, scheduled_at)"
    ]
  end

  defp try_create_vec_table(conn) do
    vec_ddl = """
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_nodes USING vec0(
      embedding float[384],
      uri TEXT PRIMARY KEY
    )
    """

    case exec(conn, vec_ddl) do
      :ok ->
        :ok

      {:error, _} ->
        # sqlite-vec extension not available, continue without vector search
        Logger.info("sqlite-vec extension not available, vector search disabled")
        :ok
    end
  end
end
