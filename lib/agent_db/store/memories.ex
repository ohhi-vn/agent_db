defmodule AgentDb.Store.Memories do
  @moduledoc false

  # memory_meta operations over a SQLite connection. Pure functions: the caller
  # supplies the connection (writer for mutations, reader for queries).
  #
  # One row per assertion ever made at a URI. The row whose status is 'active'
  # holds the value that is also in nodes.content; every earlier row is retained
  # as 'superseded' and points at the assertion that replaced it, so a revised
  # belief resolves to one active value without erasing the history.
  #
  # Supersession is insert-then-link rather than link-then-insert: the successor
  # row is written first, so the predecessor's self-referencing `supersedes`
  # never names a row that does not exist yet.

  alias AgentDb.Store.SQLite

  @type row :: %{
          id: integer(),
          uri: String.t(),
          value: String.t(),
          confidence: float(),
          source: String.t() | nil,
          status: :active | :superseded,
          supersedes: integer() | nil,
          created_at: integer(),
          updated_at: integer()
        }

  @columns "id, uri, value, confidence, source, status, supersedes, created_at, updated_at"

  @doc """
  Records a new assertion at `uri` and supersedes any prior active assertion
  there, atomically. Returns the newly recorded row.
  """
  @spec record(SQLite.conn(), String.t(), String.t(), float(), String.t() | nil) ::
          {:ok, row()} | {:error, term()}
  def record(conn, uri, value, confidence, source) do
    SQLite.transaction(conn, fn c ->
      now = System.system_time(:millisecond)

      with {:ok, id} <- insert_assertion(c, uri, value, confidence, source, now),
           :ok <- supersede_prior(c, uri, id, now),
           {:ok, row} <- fetch_by_id(c, id) do
        {:ok, row}
      end
    end)
  end

  defp insert_assertion(conn, uri, value, confidence, source, now) do
    with :ok <-
           SQLite.exec_write(
             conn,
             """
             INSERT INTO memory_meta (uri, value, confidence, source, status, supersedes, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, 'active', NULL, ?5, ?5)
             """,
             [uri, value, confidence, source, now]
           ),
         {:ok, id} <- SQLite.last_insert_rowid(conn) do
      {:ok, id}
    end
  end

  # Only the row that was active is superseded. Rows already superseded keep
  # the successor they were replaced by, so a chain longer than one revision
  # still reads as a chain rather than collapsing onto the newest row.
  defp supersede_prior(conn, uri, successor_id, now) do
    SQLite.exec_write(
      conn,
      """
      UPDATE memory_meta
      SET status = 'superseded', supersedes = ?2, updated_at = ?3
      WHERE uri = ?1 AND status = 'active' AND id <> ?2
      """,
      [uri, successor_id, now]
    )
  end

  @doc "The active assertion at `uri`, or nil when the URI holds no memory."
  @spec active_at(SQLite.conn(), String.t()) :: {:ok, row() | nil} | {:error, term()}
  def active_at(conn, uri) do
    case SQLite.query_one(
           conn,
           "SELECT #{@columns} FROM memory_meta WHERE uri = ?1 AND status = 'active'",
           [uri]
         ) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row_to_row(row)}
      {:error, _} = err -> err
    end
  end

  @doc "True when any assertion is recorded at `uri`, active or superseded."
  @spec exists_at?(SQLite.conn(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def exists_at?(conn, uri) do
    # LIMIT 1: a revised slot holds several rows, and this is an existence
    # question, not a single-row fetch.
    case SQLite.query_one(conn, "SELECT 1 FROM memory_meta WHERE uri = ?1 LIMIT 1", [uri]) do
      {:ok, nil} -> {:ok, false}
      {:ok, _row} -> {:ok, true}
      {:error, _} = err -> err
    end
  end

  @doc """
  Assertions at `prefix` or beneath it, whose status is in `statuses`, ordered
  by descending confidence then URI then id so equal confidences order
  deterministically. `term`, when given, restricts to assertions whose value
  contains it, case-insensitively.

  Matching is exact-uri-or-descendant rather than a bare string prefix, so a
  scope of `.../preferences` reaches `.../preferences/language` without also
  reaching a sibling named `preferences-extra`.
  """
  @spec list(SQLite.conn(), String.t(), String.t() | nil, [:active | :superseded]) ::
          {:ok, [row()]} | {:error, term()}
  def list(conn, prefix, term, statuses) do
    marks = Enum.map_join(statuses, ", ", fn status -> "'#{status}'" end)
    scope = "(uri = ?1 OR uri LIKE ?2 ESCAPE '\\')"

    {where, args} =
      case term do
        nil ->
          {"#{scope} AND status IN (#{marks})", [prefix, descendant_pattern(prefix)]}

        term ->
          pattern = "%" <> like_escape(String.downcase(term)) <> "%"

          {"#{scope} AND status IN (#{marks}) AND lower(value) LIKE ?3 ESCAPE '\\'",
           [prefix, descendant_pattern(prefix), pattern]}
      end

    case SQLite.query(
           conn,
           "SELECT #{@columns} FROM memory_meta WHERE #{where} ORDER BY confidence DESC, uri ASC, id ASC",
           args
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_row/1)}
      {:error, _} = err -> err
    end
  end

  defp descendant_pattern(prefix), do: like_escape(prefix <> "/") <> "%"

  @doc "Every assertion at `uri`, oldest first, so a chain reads in order."
  @spec history(SQLite.conn(), String.t()) :: {:ok, [row()]} | {:error, term()}
  def history(conn, uri) do
    case SQLite.query(
           conn,
           "SELECT #{@columns} FROM memory_meta WHERE uri = ?1 ORDER BY id ASC",
           [uri]
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_row/1)}
      {:error, _} = err -> err
    end
  end

  @doc "Deletes every assertion at `uri`, superseded ones included."
  @spec delete_for_uri(SQLite.conn(), String.t()) :: :ok | {:error, term()}
  def delete_for_uri(conn, uri) do
    SQLite.exec_write(conn, "DELETE FROM memory_meta WHERE uri = ?1", [uri])
  end

  defp fetch_by_id(conn, id) do
    case SQLite.query_one(
           conn,
           "SELECT #{@columns} FROM memory_meta WHERE id = ?1",
           [id]
         ) do
      {:ok, nil} -> {:error, :assertion_not_found}
      {:ok, row} -> {:ok, row_to_row(row)}
      {:error, _} = err -> err
    end
  end

  # LIKE escaping for a URI prefix or a user-supplied term. Mirrors
  # AgentDb.Store.Nodes.like_escape/1, which is not exposed for other tables.
  defp like_escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp row_to_row([
         id,
         uri,
         value,
         confidence,
         source,
         status,
         supersedes,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      uri: uri,
      value: value,
      confidence: confidence * 1.0,
      source: source,
      status: safe_status(status),
      supersedes: supersedes,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp safe_status("active"), do: :active
  defp safe_status("superseded"), do: :superseded
end
