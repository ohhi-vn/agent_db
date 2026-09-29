defmodule AgentDb.Store.Nodes do
  @moduledoc false

  # Node table operations over a SQLite connection. Pure functions: the caller
  # supplies the connection (writer for mutations, reader for queries).

  alias AgentDb.JobQueue
  alias AgentDb.Store.SQLite

  @type kind :: :doc | :dir
  @type node_row :: %{
          uri: String.t(),
          parent_uri: String.t() | nil,
          name: String.t(),
          kind: kind(),
          content: String.t() | nil,
          abstract: String.t() | nil,
          overview: String.t() | nil
        }

  @doc "Fetches one node by URI."
  @spec get(SQLite.conn(), String.t()) :: {:ok, node_row() | nil} | {:error, term()}
  def get(conn, uri) do
    case SQLite.query_one(
           conn,
           "SELECT uri, parent_uri, name, kind, content, abstract, overview FROM nodes WHERE uri = ?1",
           [uri]
         ) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row_to_node(row)}
      {:error, _} = err -> err
    end
  end

  @doc "Lists children (direct) of a parent URI, ordered by name."
  @spec children(SQLite.conn(), String.t()) :: {:ok, [node_row()]} | {:error, term()}
  def children(conn, parent_uri) do
    case SQLite.query(
           conn,
           "SELECT uri, parent_uri, name, kind, content, abstract, overview FROM nodes WHERE parent_uri = ?1 ORDER BY name",
           [parent_uri]
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_node/1)}
      {:error, _} = err -> err
    end
  end

  @doc "Direct children names only (for dir cache)."
  @spec child_names(SQLite.conn(), String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def child_names(conn, parent_uri) do
    case SQLite.query(conn, "SELECT name FROM nodes WHERE parent_uri = ?1", [parent_uri]) do
      {:ok, rows} -> {:ok, MapSet.new(rows, &hd/1)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Inserts or updates a document node. NULL summary args keep existing values
  (partial update semantics for re-writes).
  """
  @spec upsert_doc(SQLite.conn(), String.t(), String.t() | nil, String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def upsert_doc(conn, uri, parent_uri, name, content, opts \\ []) do
    abstract = Keyword.get(opts, :abstract)
    overview = Keyword.get(opts, :overview)
    now = System.system_time(:millisecond)

    SQLite.exec_write(
      conn,
      """
      INSERT INTO nodes (uri, parent_uri, name, kind, content, abstract, overview, created_at, updated_at)
      VALUES (?1, ?2, ?3, 'doc', ?4, ?5, ?6, ?7, ?7)
      ON CONFLICT(uri) DO UPDATE SET
        content = excluded.content,
        abstract = COALESCE(?5, nodes.abstract),
        overview = COALESCE(?6, nodes.overview),
        updated_at = ?7
      """,
      [uri, parent_uri, name, content, abstract, overview, now]
    )
  end

  @doc "Inserts a directory node if missing. No-op when it already exists."
  @spec ensure_dir(SQLite.conn(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, term()}
  def ensure_dir(conn, uri, parent_uri, name) do
    now = System.system_time(:millisecond)

    SQLite.exec_write(
      conn,
      """
      INSERT INTO nodes (uri, parent_uri, name, kind, content, created_at, updated_at)
      VALUES (?1, ?2, ?3, 'dir', NULL, ?4, ?4)
      ON CONFLICT(uri) DO NOTHING
      """,
      [uri, parent_uri, name, now]
    )
  end

  @doc """
  Deletes the subtree at `uri` (node and all descendants) from every store keyed
  by URI, in one transaction. Returns `:not_found` when absent and `:root` for
  the tree root, which is never removable.

  `vec_nodes` is skipped when the sqlite-vec extension is not loaded, since the
  table does not exist there.
  """
  @spec rm_subtree(SQLite.conn(), String.t()) :: :ok | :root | {:error, term()}
  def rm_subtree(_conn, "viking://"), do: :root

  def rm_subtree(conn, uri) do
    with {:ok, true} <- exists?(conn, uri) do
      SQLite.transaction(conn, fn c -> purge_subtree(c, uri) end)
    else
      {:ok, false} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Removes the subtree at `uri` from every store keyed by URI, on a connection the
  caller already holds.

  Takes the connection rather than opening a transaction of its own, so an
  operation that has more to do in the same step -- replacing a subtree, for
  instance -- can make the removal and what follows it one atomic step. Outside a
  transaction it stands alone, exactly as `rm_subtree/2` does.
  """
  @spec purge_subtree(SQLite.conn(), String.t()) :: :ok | {:error, term()}
  def purge_subtree(_conn, "viking://"), do: {:error, :root}
  def purge_subtree(conn, uri), do: purge_uri_state(conn, uri)

  # Every URI-keyed delete lives here. Adding a store that holds state per URI
  # means adding a line to this function, so a new table cannot be silently
  # left behind holding rows for removed nodes.
  #
  # All five share one prefix predicate so they cannot disagree about which
  # URIs are "in the subtree". For `nodes` the removal is doubly guaranteed:
  # by this predicate and by the parent_uri ON DELETE CASCADE foreign key.
  defp purge_uri_state(conn, uri) do
    prefix = like_escape(uri <> "/") <> "%"

    with :ok <- delete_nodes(conn, uri, prefix),
         :ok <- delete_vec_nodes(conn, uri, prefix),
         :ok <- JobQueue.cancel_for_uri(conn, uri),
         :ok <- delete_commit_meta(conn, uri, prefix),
         :ok <- delete_memory_meta(conn, uri, prefix) do
      :ok
    end
  end

  defp delete_nodes(conn, uri, prefix) do
    SQLite.exec_write(
      conn,
      "DELETE FROM nodes WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
      [uri, prefix]
    )
  end

  # vec_nodes is a vec0 virtual table that only exists when sqlite-vec loaded.
  defp delete_vec_nodes(conn, uri, prefix) do
    if SQLite.vec_available?(conn) do
      SQLite.exec_write(
        conn,
        "DELETE FROM vec_nodes WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
        [uri, prefix]
      )
    else
      :ok
    end
  end

  # Keyed by destination_uri only, never session_id: a session committed to
  # several destinations loses bookkeeping for the removed one and keeps it for
  # the rest. Leaving a stale row here is what makes a later re-commit of an
  # unchanged session report :unchanged without restoring the document.
  defp delete_commit_meta(conn, uri, prefix) do
    SQLite.exec_write(
      conn,
      "DELETE FROM commit_meta WHERE destination_uri = ?1 OR destination_uri LIKE ?2 ESCAPE '\\'",
      [uri, prefix]
    )
  end

  # Superseded assertions included, not just the active one: a removal that left
  # them behind would let a later write at the same URI inherit a value the
  # caller asked to have removed.
  defp delete_memory_meta(conn, uri, prefix) do
    SQLite.exec_write(
      conn,
      "DELETE FROM memory_meta WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
      [uri, prefix]
    )
  end

  @doc """
  All doc nodes whose content/abstract/overview contain the (case-insensitive)
  substring, optionally limited to a subtree prefix. Caller passes the raw
  term; escaping happens here.
  """
  @spec search(SQLite.conn(), String.t(), String.t() | nil) ::
          {:ok, [node_row()]} | {:error, term()}
  def search(conn, term, scope_prefix) do
    pattern = "%" <> like_escape(String.downcase(term)) <> "%"

    {where, args} =
      case scope_prefix do
        nil ->
          {"kind = 'doc' AND (lower(COALESCE(content,'')) LIKE ? ESCAPE '\\' OR lower(COALESCE(abstract,'')) LIKE ? ESCAPE '\\' OR lower(COALESCE(overview,'')) LIKE ? ESCAPE '\\')",
           [pattern, pattern, pattern]}

        prefix when is_binary(prefix) ->
          {"kind = 'doc' AND uri LIKE ? ESCAPE '\\' AND (lower(COALESCE(content,'')) LIKE ? ESCAPE '\\' OR lower(COALESCE(abstract,'')) LIKE ? ESCAPE '\\' OR lower(COALESCE(overview,'')) LIKE ? ESCAPE '\\')",
           [like_escape(prefix) <> "%", pattern, pattern, pattern]}
      end

    case SQLite.query(
           conn,
           "SELECT uri, parent_uri, name, kind, content, abstract, overview FROM nodes WHERE " <>
             where,
           args
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_node/1)}
      {:error, _} = err -> err
    end
  end

  @doc "True when a node row exists at `uri`."
  @spec exists?(SQLite.conn(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def exists?(conn, uri) do
    case SQLite.query_one(conn, "SELECT 1 FROM nodes WHERE uri = ?1", [uri]) do
      {:ok, nil} -> {:ok, false}
      {:ok, _row} -> {:ok, true}
      {:error, _} = err -> err
    end
  end

  defp row_to_node([uri, parent_uri, name, kind, content, abstract, overview]) do
    %{
      uri: uri,
      parent_uri: parent_uri,
      name: name,
      kind: safe_kind(kind),
      content: content,
      abstract: abstract,
      overview: overview
    }
  end

  defp safe_kind("doc"), do: :doc
  defp safe_kind("dir"), do: :dir

  @doc "Escapes LIKE wildcards in user text (active escape char is backslash)."
  @spec like_escape(String.t()) :: String.t()
  def like_escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc "Updates the updated_at timestamp for a node."
  @spec update_updated_at(SQLite.conn(), String.t(), integer()) :: :ok | {:error, term()}
  def update_updated_at(conn, uri, timestamp) do
    SQLite.exec_write(
      conn,
      "UPDATE nodes SET updated_at = ?1 WHERE uri = ?2",
      [timestamp, uri]
    )
  end
end
