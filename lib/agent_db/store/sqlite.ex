defmodule AgentDb.Store.SQLite do
  @moduledoc false

  # Direct SQLite access via exqlite. All functions are pure wrappers over
  # Exqlite.Sqlite3 with explicit connection passing - no process ownership here.

  alias Exqlite.Sqlite3

  require Logger

  @type conn :: Sqlite3.db()
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
      {:ok, _} -> :ok
      {:error, _} ->
        # Extension not loaded, try to load it
        case exec(conn, "SELECT load_extension('vec0')") do
          {:ok, _} -> :ok
          {:error, _} ->
            # Try alternative names
            case exec(conn, "SELECT load_extension('sqlite_vec')") do
              {:ok, _} -> :ok
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

    # Then try to create vec_nodes table (optional, requires sqlite-vec extension)
    try_create_vec_table(conn)
    :ok
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
      :ok -> :ok
      {:error, _} ->
        # sqlite-vec extension not available, continue without vector search
        Logger.info("sqlite-vec extension not available, vector search disabled")
        :ok
    end
  end
end
