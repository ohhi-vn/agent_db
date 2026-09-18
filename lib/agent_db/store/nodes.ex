defmodule AgentDb.Store.Nodes do
  @moduledoc false

  # Node table operations over a SQLite connection. Pure functions: the caller
  # supplies the connection (writer for mutations, reader for queries).

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

  @doc "Deletes the subtree at `uri` (node and all descendants). Returns :not_found when absent."
  @spec rm_subtree(SQLite.conn(), String.t()) :: :ok | {:error, term()}
  def rm_subtree(conn, uri) do
    with {:ok, [[1]]} <- exists?(conn, uri),
         :ok <- delete_subtree(conn, uri) do
      :ok
    else
      {:ok, [[]]} -> {:error, :not_found}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = err -> err
    end
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

  defp exists?(conn, uri) do
    SQLite.query(conn, "SELECT 1 FROM nodes WHERE uri = ?1", [uri])
  end

  defp delete_subtree(conn, uri) do
    SQLite.exec_write(
      conn,
      "DELETE FROM nodes WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
      [uri, like_escape(uri <> "/") <> "%"]
    )
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
