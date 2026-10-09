defmodule AgentDb.Store.SQLite do
  @moduledoc false

  # Direct SQLite access via exqlite. All functions are pure wrappers over
  # Exqlite.Sqlite3 with explicit connection passing - no process ownership here.

  alias AgentDb.Observability
  alias Exqlite.Sqlite3

  @type conn :: Exqlite.Sqlite3.db()
  @type ok_err :: :ok | {:error, term()}

  @doc "Opens a SQLite database with WAL and foreign_keys enabled. Loads sqlite-vec extension."
  @spec open(String.t()) :: {:ok, conn()} | {:error, term()}
  def open(path) do
    with {:ok, conn} <- Sqlite3.open(path),
         :ok <- exec(conn, "PRAGMA journal_mode=WAL"),
         :ok <- exec(conn, "PRAGMA foreign_keys=ON"),
         :ok <- exec(conn, "PRAGMA busy_timeout=5000"),
         :ok <- ensure_vec_extension(conn) do
      {:ok, conn}
    end
  end

  defp ensure_vec_extension(conn) do
    case load_vec_extension(conn) do
      :ok ->
        :ok

      {:error, :vector_index_unavailable} ->
        Observability.log(:warning,
          component: :storage,
          operation: :vector_index,
          outcome: :unavailable
        )

        :ok
    end
  end

  # Loads the sqlite-vec extension for vector search.
  @spec load_vec_extension(conn()) :: :ok | {:error, :vector_index_unavailable}
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
                {:error, :vector_index_unavailable}
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
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Sqlite3.bind(stmt, args),
               :done <- Sqlite3.step(conn, stmt) do
            :ok
          else
            {:error, _} = err -> err
            other -> {:error, {:unexpected_step_result, other}}
          end
        after
          Sqlite3.release(conn, stmt)
        end

      {:error, _} = err ->
        err
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
        Observability.log(:error,
          component: :storage,
          operation: :rollback,
          outcome: :error,
          reason: reason
        )

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
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Sqlite3.bind(stmt, args),
               {:ok, rows} <- collect_rows(conn, stmt, [], Sqlite3.step(conn, stmt)) do
            {:ok, rows}
          else
            {:error, _} = err -> err
          end
        after
          Sqlite3.release(conn, stmt)
        end

      {:error, _} = err ->
        err
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

  @max_vec_dim 8192
  @max_vec_tables 16

  @doc "The virtual table holding vectors of `dim` dimensions."
  @spec vec_table(pos_integer()) :: String.t()
  def vec_table(dim) when is_integer(dim), do: "vec_nodes_#{dim}"

  @doc "True when `dim` may name a vector table."
  @spec valid_vec_dim?(term()) :: boolean()
  def valid_vec_dim?(dim) when is_integer(dim) and dim >= 1 and dim <= @max_vec_dim, do: true
  def valid_vec_dim?(_), do: false

  @doc "Dims derived from a float32 blob (`dim = byte_size(blob) / 4`)."
  @spec vec_dim(binary()) :: {:ok, pos_integer()} | {:error, term()}
  def vec_dim(blob) when is_binary(blob) do
    if rem(byte_size(blob), 4) == 0 and byte_size(blob) > 0 do
      dim = div(byte_size(blob), 4)

      if valid_vec_dim?(dim) do
        {:ok, dim}
      else
        {:error, {:invalid_dim, dim}}
      end
    else
      {:error, {:invalid_dim, byte_size(blob)}}
    end
  end

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
      :ok ->
        with :ok <- add_missing_columns(conn) do
          migrate_memory_status_check(conn)
        end

      {:error, _} = err ->
        err
    end
    |> case do
      :ok ->
        # Then try to create vec_nodes table (optional, requires sqlite-vec extension)
        try_create_vec_table(conn)
        migrate_legacy_vec_table(conn)
        reconcile_orphan_embeddings(conn)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Creates `vec_nodes_<dim>` lazily, behind `vec_available?/1`.

  `CREATE VIRTUAL TABLE IF NOT EXISTS` converges concurrent creators. Absurd
  dims (0 or above 8192) are refused, and beyond `@max_vec_tables` distinct
  dims the table is not created, so a misconfigured provider creates an empty
  table instead of deleting good vectors but cannot proliferate unboundedly.
  """
  @spec ensure_vec_table(conn(), pos_integer()) :: :ok | {:error, term()}
  def ensure_vec_table(conn, dim) do
    cond do
      not valid_vec_dim?(dim) ->
        {:error, {:invalid_dim, dim}}

      not vec_available?(conn) ->
        :ok

      true ->
        case list_vec_dims(conn) do
          {:ok, dims} ->
            if length(dims) >= @max_vec_tables and dim not in dims do
              Observability.log(:warning,
                component: :storage,
                operation: :vector_index,
                outcome: :refused,
                reason: :too_many_dims
              )

              {:error, :too_many_dims}
            else
              exec(conn, vec_ddl(dim))
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp vec_ddl(dim) do
    """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{vec_table(dim)} USING vec0(
      embedding float[#{dim}],
      uri TEXT PRIMARY KEY
    )
    """
  end

  @doc "Dims with a vector table on disk, treating legacy `vec_nodes` as 384."
  @spec list_vec_dims(conn()) :: {:ok, [pos_integer()]} | {:error, term()}
  def list_vec_dims(conn) do
    case query(
           conn,
           "SELECT name FROM sqlite_master WHERE type = 'table' AND (name = 'vec_nodes' OR name LIKE 'vec_nodes\\_%' ESCAPE '\\')",
           []
         ) do
      {:ok, rows} ->
        dims =
          rows
          |> List.flatten()
          |> Enum.map(&parse_vec_table/1)
          |> Enum.filter(&valid_vec_dim?/1)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, dims}

      {:error, _} = err ->
        err
    end
  end

  defp parse_vec_table("vec_nodes"), do: 384

  defp parse_vec_table("vec_nodes_" <> rest) do
    case Integer.parse(rest) do
      {dim, ""} -> dim
      _ -> :invalid
    end
  end

  defp parse_vec_table(_), do: :invalid

  @doc "The last observed embedding dim, or `:unknown` before any vector."
  @spec get_active_dim(conn()) :: {:ok, pos_integer() | :unknown} | {:error, term()}
  def get_active_dim(conn) do
    case query_one(conn, "SELECT value FROM vec_meta WHERE key = 'active_dim'", []) do
      {:ok, nil} -> derive_active_dim(conn)
      {:ok, [value]} -> parse_active_dim(conn, value)
      {:error, _} = err -> err
    end
  end

  defp parse_active_dim(conn, value) do
    case Integer.parse(to_string(value)) do
      {dim, ""} ->
        if valid_vec_dim?(dim), do: {:ok, dim}, else: derive_active_dim(conn)

      _ ->
        derive_active_dim(conn)
    end
  end

  defp derive_active_dim(conn) do
    case list_vec_dims(conn) do
      {:ok, [dim]} -> {:ok, dim}
      {:ok, []} -> {:ok, :unknown}
      {:ok, dims} -> most_covered_dim(conn, dims)
      {:error, _} = err -> err
    end
  end

  defp most_covered_dim(conn, dims) do
    counts =
      Enum.map(dims, fn dim ->
        case query_one(conn, "SELECT COUNT(*) FROM \"#{vec_table(dim)}\"", []) do
          {:ok, [n]} when is_integer(n) -> {n, dim}
          _ -> {0, dim}
        end
      end)

    case Enum.max_by(counts, &elem(&1, 0), fn -> {0, :unknown} end) do
      {0, :unknown} -> {:ok, :unknown}
      {_n, dim} -> {:ok, dim}
    end
  end

  @doc false
  @spec set_active_dim(conn(), pos_integer()) :: ok_err()
  def set_active_dim(conn, dim) when is_integer(dim) do
    exec_write(
      conn,
      "INSERT INTO vec_meta (key, value) VALUES ('active_dim', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [
        to_string(dim)
      ]
    )
  end

  @doc """
  Drops a non-active dim table. Refuses the active dim; boot never calls this.
  """
  @spec prune_vec_table(conn(), pos_integer()) :: :ok | {:error, term()}
  def prune_vec_table(conn, dim) do
    with {:ok, active} <- get_active_dim(conn) do
      cond do
        not valid_vec_dim?(dim) -> {:error, {:invalid_dim, dim}}
        active != :unknown and dim == active -> {:error, :active_dim}
        true -> drop_vec_tables(conn, dim)
      end
    end
  end

  defp drop_vec_tables(conn, 384) do
    with :ok <- drop_table(conn, vec_table(384)),
         :ok <- drop_table(conn, "vec_nodes") do
      :ok
    end
  end

  defp drop_vec_tables(conn, dim), do: drop_table(conn, vec_table(dim))

  defp drop_table(conn, table) do
    case exec(conn, "DROP TABLE IF EXISTS \"#{table}\"") do
      :ok -> :ok
      {:error, _} = err -> err
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
    {"job_queue", "last_error", "TEXT"},
    # How much a memory matters, set at record time beside confidence.
    {"memory_meta", "importance", "REAL"},
    # When a recall last surfaced the assertion, for recency-aware ranking.
    # NULL is "never surfaced", which ranks as maximally stale -- honest,
    # since it is.
    {"memory_meta", "last_surfaced_at", "INTEGER"}
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

  # The one place the memory assertion table's shape is decided, so the base
  # schema and the legacy rebuild cannot disagree about it.
  defp memory_meta_ddl do
    """
    CREATE TABLE IF NOT EXISTS memory_meta (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uri TEXT NOT NULL,
      value TEXT NOT NULL,
      confidence REAL NOT NULL,
      importance REAL,
      source TEXT,
      status TEXT NOT NULL CHECK (status IN ('active', 'superseded', 'candidate')),
      supersedes INTEGER REFERENCES memory_meta(id),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      last_surfaced_at INTEGER,
      FOREIGN KEY (uri) REFERENCES nodes(uri) ON DELETE CASCADE
    )
    """
  end

  defp table_columns(conn, table) do
    case query(conn, "PRAGMA table_info(#{table})", []) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [_cid, name | _rest] -> name end)}
      {:error, _} = err -> err
    end
  end

  # A CHECK cannot be widened by ALTER, so a `memory_meta` created before the
  # `candidate` status existed would reject candidate rows even after the new
  # columns arrive. Rebuild it once (rename, create, copy, drop) inside one
  # transaction: rows are preserved, and a fresh table already carrying the new
  # CHECK is left alone. Idempotent: the stored DDL names the new status after
  # the first run.
  defp migrate_memory_status_check(conn) do
    case query_one(
           conn,
           "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'memory_meta'",
           []
         ) do
      {:ok, nil} ->
        :ok

      {:ok, [sql]} ->
        if String.contains?(to_string(sql || ""), "candidate") do
          :ok
        else
          rebuild_memory_meta(conn)
        end

      {:error, _} = err ->
        err
    end
  end

  defp rebuild_memory_meta(conn) do
    with {:ok, existing} <- table_columns(conn, "memory_meta") do
      desired =
        ~w(id uri value confidence importance source status supersedes created_at updated_at last_surfaced_at)

      copy = Enum.filter(desired, &(&1 in existing))

      transaction(conn, fn c ->
        with :ok <- exec(c, "DROP INDEX IF EXISTS idx_memory_meta_uri_status"),
             :ok <- exec(c, "DROP INDEX IF EXISTS idx_memory_meta_status"),
             :ok <- exec(c, "ALTER TABLE memory_meta RENAME TO memory_meta_legacy"),
             :ok <- exec(c, memory_meta_ddl()),
             :ok <-
               exec_write(
                 c,
                 "INSERT INTO memory_meta (#{Enum.join(copy, ", ")}) SELECT #{Enum.join(copy, ", ")} FROM memory_meta_legacy",
                 []
               ),
             :ok <- exec(c, "DROP TABLE memory_meta_legacy"),
             :ok <-
               exec(
                 c,
                 "CREATE INDEX IF NOT EXISTS idx_memory_meta_uri_status ON memory_meta(uri, status)"
               ),
             :ok <-
               exec(c, "CREATE INDEX IF NOT EXISTS idx_memory_meta_status ON memory_meta(status)") do
          :ok
        end
      end)
      |> case do
        :ok ->
          Observability.log(:info,
            component: :storage,
            operation: :rebuild_memory_meta,
            outcome: :ok
          )

          :ok

        {:error, reason} ->
          Observability.log(:warning,
            component: :storage,
            operation: :rebuild_memory_meta,
            outcome: :error,
            reason: reason
          )

          {:error, reason}
      end
    end
  end

  # Releases vec rows left behind by removals that predate the purge in
  # Nodes.purge_uri_state/2. Such rows are already invisible to search (the
  # query joins nodes), so this is about reclaiming storage and about not
  # letting a node recreated at an old deleted URI inherit a stale embedding.
  # Guarded by an existence check so a clean or large index is not scanned
  # on every boot. Runs over every dim table plus legacy `vec_nodes`.
  defp reconcile_orphan_embeddings(conn) do
    if vec_available?(conn) do
      case list_vec_tables(conn) do
        {:ok, tables} -> Enum.each(tables, &reconcile_orphan_table(conn, &1))
        {:error, _} -> :ok
      end
    end

    :ok
  end

  defp list_vec_tables(conn) do
    case query(
           conn,
           "SELECT name FROM sqlite_master WHERE type = 'table' AND (name = 'vec_nodes' OR name LIKE 'vec_nodes\\_%' ESCAPE '\\')",
           []
         ) do
      {:ok, rows} -> {:ok, List.flatten(rows)}
      {:error, _} = err -> err
    end
  end

  defp reconcile_orphan_table(conn, table) do
    case query_one(
           conn,
           "SELECT EXISTS(SELECT 1 FROM \"#{table}\" v LEFT JOIN nodes n ON n.uri = v.uri WHERE n.uri IS NULL)"
         ) do
      {:ok, [1]} ->
        case exec_write(
               conn,
               "DELETE FROM \"#{table}\" WHERE uri IN (SELECT v.uri FROM \"#{table}\" v LEFT JOIN nodes n ON n.uri = v.uri WHERE n.uri IS NULL)"
             ) do
          :ok ->
            Observability.log(:info,
              component: :storage,
              operation: :reclaim_orphans,
              outcome: :ok
            )

            :ok

          {:error, reason} ->
            Observability.log(:warning,
              component: :storage,
              operation: :reclaim_orphans,
              outcome: :error,
              reason: reason
            )

            :ok
        end

      _ ->
        :ok
    end
  end

  # Existing `vec_nodes` (384) is treated as `vec_nodes_384`: on a host with
  # the extension, create the namespaced table and copy missing rows once, so
  # later code reads only namespaced tables. Additive and idempotent; inert
  # without the extension.
  defp migrate_legacy_vec_table(conn) do
    if vec_available?(conn) do
      with {:ok, tables} <- list_vec_tables(conn),
           true <- "vec_nodes" in tables,
           {:ok, dims} <- list_vec_dims(conn),
           false <- 384 in dims and "vec_nodes_384" in tables do
        with :ok <- exec(conn, vec_ddl(384)),
             :ok <-
               exec_write(
                 conn,
                 "INSERT OR IGNORE INTO \"#{vec_table(384)}\" (embedding, uri) SELECT embedding, uri FROM vec_nodes",
                 []
               ),
             {:ok, _} <- set_active_dim_if_unset(conn, 384) do
          Observability.log(:info,
            component: :storage,
            operation: :migrate_vec_nodes,
            outcome: :ok
          )

          :ok
        else
          _ -> :ok
        end
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp set_active_dim_if_unset(conn, dim) do
    case query_one(conn, "SELECT value FROM vec_meta WHERE key = 'active_dim'", []) do
      {:ok, nil} -> set_active_dim(conn, dim)
      {:ok, _} -> {:ok, :already_set}
      {:error, _} = err -> err
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
      memory_meta_ddl(),
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
      "CREATE INDEX IF NOT EXISTS idx_job_queue_status_sched ON job_queue(status, scheduled_at)",
      "CREATE INDEX IF NOT EXISTS idx_job_queue_status_kind_sched ON job_queue(status, kind, scheduled_at)",
      "CREATE INDEX IF NOT EXISTS idx_job_queue_payload_uri ON job_queue(json_extract(payload, '$.uri'))",
      """
      CREATE TABLE IF NOT EXISTS vec_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      """
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
        Observability.log(:info,
          component: :storage,
          operation: :vector_index,
          outcome: :unavailable
        )

        :ok
    end
  end
end
