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

  alias AgentDb.Store.{Nodes, SQLite}

  @type row :: %{
          id: integer(),
          uri: String.t(),
          value: String.t(),
          confidence: float(),
          importance: float() | nil,
          source: String.t() | nil,
          status: :active | :superseded | :candidate,
          supersedes: integer() | nil,
          created_at: integer(),
          updated_at: integer(),
          last_surfaced_at: integer() | nil
        }

  @type status :: :active | :superseded | :candidate

  @default_importance 0.5

  # The bound a recall materialises when the caller names none, and the largest
  # bound a caller may name. Both are the number the store had hardcoded before
  # the bound was caller-controlled, so the default changes no existing answer.
  @default_top_k 500
  @max_top_k 500

  @columns "id, uri, value, confidence, importance, source, status, supersedes, created_at, updated_at, last_surfaced_at"

  @doc """
  Records a new assertion at `uri` and supersedes any prior active assertion
  there. Returns the newly recorded row.

  The caller holds the transaction: this is a set of statements, not a
  transaction of its own, so a caller can write the document, the assertion,
  and the jobs that depend on them as one outcome.

  Options:
    - `:importance` - how much the fact matters (defaults to #{@default_importance} when absent)
    - `:status` - `:active` (default) or `:candidate`. A candidate is stored
      without superseding anything, so it never disturbs the active belief.
  """
  @spec record(SQLite.conn(), String.t(), String.t(), float(), String.t() | nil, keyword()) ::
          {:ok, row()} | {:error, term()}
  def record(conn, uri, value, confidence, source, opts \\ []) do
    importance = Keyword.get(opts, :importance, @default_importance)
    status = Keyword.get(opts, :status, :active)
    now = System.system_time(:millisecond)

    with {:ok, id} <-
           insert_assertion(conn, uri, value, confidence, importance, source, status, now),
         :ok <- maybe_supersede_prior(conn, uri, id, status, now),
         {:ok, row} <- fetch_by_id(conn, id) do
      {:ok, row}
    end
  end

  @doc """
  The active assertion at exactly `uri` whose value is exactly `value`, or nil
  when the URI holds no such assertion.

  An exact match, not a substring one: re-recording the same fact at the same
  URI is the case this answers, and a value that merely contains another is
  a different belief.
  """
  @spec active_at_value(SQLite.conn(), String.t(), String.t()) ::
          {:ok, row() | nil} | {:error, term()}
  def active_at_value(conn, uri, value) do
    case SQLite.query_one(
           conn,
           "SELECT #{@columns} FROM memory_meta WHERE uri = ?1 AND status = 'active' AND value = ?2",
           [uri, value]
         ) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row_to_row(row)}
      {:error, _} = err -> err
    end
  end

  defp insert_assertion(conn, uri, value, confidence, importance, source, status, now) do
    with :ok <-
           SQLite.exec_write(
             conn,
             """
             INSERT INTO memory_meta (uri, value, confidence, importance, source, status, supersedes, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, ?7)
             """,
             [uri, value, confidence, importance, source, to_string(status), now]
           ),
         {:ok, id} <- SQLite.last_insert_rowid(conn) do
      {:ok, id}
    end
  end

  # Only an active record revises the belief at its URI. A candidate waits
  # beside it; promotion is what makes it current.
  defp maybe_supersede_prior(conn, uri, id, :active, now), do: supersede_prior(conn, uri, id, now)
  defp maybe_supersede_prior(_conn, _uri, _id, _status, _now), do: :ok

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

  @doc "The latest waiting candidate at `uri`, or nil when none is waiting."
  @spec candidate_at(SQLite.conn(), String.t()) :: {:ok, row() | nil} | {:error, term()}
  def candidate_at(conn, uri) do
    case SQLite.query_one(
           conn,
           "SELECT #{@columns} FROM memory_meta WHERE uri = ?1 AND status = 'candidate' ORDER BY id DESC",
           [uri]
         ) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row} -> {:ok, row_to_row(row)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Promotes the latest candidate at `uri` to the active assertion, superseding
  any prior active one there and dropping other waiting candidates there.
  Returns the promoted, now-active row. `{:error, :no_candidate}` when none is
  waiting.

  The caller holds the transaction: this is a set of statements, not a
  transaction of its own, so a caller can fold the document re-write promotion
  implies into the same outcome.
  """
  @spec promote_candidate(SQLite.conn(), String.t()) ::
          {:ok, row()} | {:error, :no_candidate} | {:error, term()}
  def promote_candidate(conn, uri) do
    now = System.system_time(:millisecond)

    with {:ok, %{id: id}} <- require_candidate(conn, uri),
         :ok <-
           SQLite.exec_write(
             conn,
             "UPDATE memory_meta SET status = 'active', updated_at = ?1 WHERE id = ?2",
             [now, id]
           ),
         :ok <- supersede_prior(conn, uri, id, now),
         :ok <- drop_other_candidates(conn, uri, id),
         {:ok, row} <- fetch_by_id(conn, id) do
      {:ok, %{row | status: :active}}
    end
  end

  defp require_candidate(conn, uri) do
    case candidate_at(conn, uri) do
      {:ok, nil} -> {:error, :no_candidate}
      {:ok, candidate} -> {:ok, candidate}
      {:error, _} = err -> err
    end
  end

  defp drop_other_candidates(conn, uri, kept_id) do
    SQLite.exec_write(
      conn,
      "DELETE FROM memory_meta WHERE uri = ?1 AND status = 'candidate' AND id <> ?2",
      [uri, kept_id]
    )
  end

  @doc """
  Removes waiting candidates at `uri` without a trace. Active and superseded
  history is untouched. `{:error, :no_candidate}` when none is waiting.
  """
  @spec reject_candidate(SQLite.conn(), String.t()) ::
          :ok | {:error, :no_candidate} | {:error, term()}
  def reject_candidate(conn, uri) do
    with :ok <-
           SQLite.exec_write(
             conn,
             "DELETE FROM memory_meta WHERE uri = ?1 AND status = 'candidate'",
             [uri]
           ),
         {:ok, [deleted]} <- SQLite.query_one(conn, "SELECT changes()", []) do
      if deleted > 0, do: :ok, else: {:error, :no_candidate}
    end
  end

  @doc "Records that the assertions with these ids were surfaced by a recall."
  @spec mark_surfaced(SQLite.conn(), [integer()], integer()) :: :ok | {:error, term()}
  def mark_surfaced(_conn, [], _now), do: :ok

  def mark_surfaced(conn, ids, now) when is_list(ids) do
    marks = Enum.map_join(ids, ", ", fn _id -> "?" end)

    SQLite.exec_write(
      conn,
      "UPDATE memory_meta SET last_surfaced_at = ?1 WHERE id IN (#{marks})",
      [now | ids]
    )
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

  Options:
    - `:top_k` - the bound this read materialises, 1..#{@max_top_k} (default
      #{@default_top_k}). Over-fetches one row so the bound being reached is
      known exactly rather than guessed from a count that equals it, and
      every returned row reports the answer as `truncated: true | false`.
      Out of range is `{:error, {:invalid_limit, value}}`.
    - `:source` - restricts to assertions recorded from that provenance.

  Matching is exact-uri-or-descendant rather than a bare string prefix, so a
  scope of `.../preferences` reaches `.../preferences/language` without also
  reaching a sibling named `preferences-extra`.
  """
  @spec list(SQLite.conn(), String.t(), String.t() | nil, [status()], keyword()) ::
          {:ok, [row()]} | {:error, term()}
  def list(conn, prefix, term, statuses, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    marks = Enum.map_join(statuses, ", ", fn status -> "'#{status}'" end)

    with {:ok, fetch_limit} <- fetch_bound(top_k) do
      where = ["(uri = ?1 OR uri LIKE ?2 ESCAPE '\\')", "status IN (#{marks})"]
      args = [prefix, descendant_pattern(prefix)]

      {where, args} =
        case Keyword.get(opts, :source) do
          nil -> {where, args}
          source -> add_clause(where, args, "source = ?#{length(args) + 1}", source)
        end

      {where, args} =
        case term do
          nil ->
            {where, args}

          term when is_binary(term) ->
            pattern = "%" <> Nodes.like_escape(String.downcase(term)) <> "%"

            add_clause(
              where,
              args,
              "lower(value) LIKE ?#{length(args) + 1} ESCAPE '\\'",
              pattern
            )
        end

      query =
        "SELECT #{@columns} FROM memory_meta WHERE #{Enum.join(where, " AND ")} " <>
          "ORDER BY confidence DESC, uri ASC, id ASC LIMIT ?#{length(args) + 1}"

      case SQLite.query(conn, query, args ++ [fetch_limit]) do
        {:ok, rows} -> {:ok, bounded(rows, top_k)}
        {:error, _} = err -> err
      end
    end
  end

  defp add_clause(where, args, clause, value), do: {where ++ [clause], args ++ [value]}

  # One fetch beyond the bound: with it, "exactly as many rows as the bound
  # allows" is distinguishable from "one row more, cut off".
  defp fetch_bound(top_k) when is_integer(top_k) and top_k >= 1 and top_k <= @max_top_k do
    {:ok, top_k + 1}
  end

  defp fetch_bound(top_k), do: {:error, {:invalid_limit, top_k}}

  # Serves at most the bound and marks every row it keeps with whether the
  # bound was reached. Reaching exactly `top_k` rows is not truncation: the
  # fetch ran one row beyond the bound, so this many was all there was.
  defp bounded(rows, top_k) when length(rows) > top_k do
    Enum.map(Enum.take(rows, top_k), &row_to_row(&1, true))
  end

  defp bounded(rows, _top_k), do: Enum.map(rows, &row_to_row(&1, false))

  defp descendant_pattern(prefix), do: Nodes.like_escape(prefix <> "/") <> "%"

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

  defp row_to_row([
         id,
         uri,
         value,
         confidence,
         importance,
         source,
         status,
         supersedes,
         created_at,
         updated_at,
         last_surfaced_at
       ]) do
    %{
      id: id,
      uri: uri,
      value: value,
      confidence: confidence * 1.0,
      importance: importance_value(importance),
      source: source,
      status: safe_status(status),
      supersedes: supersedes,
      created_at: created_at,
      updated_at: updated_at,
      last_surfaced_at: last_surfaced_at
    }
  end

  # A bounded read marks the rows it serves; every other caller leaves the
  # flag off, since a single-row read has no bound to reach.
  defp row_to_row(row, truncated?), do: Map.put(row_to_row(row), :truncated, truncated?)

  # Legacy rows predate the column: the application maps NULL to its documented
  # default on the way out, so storage never invents a value of its own.
  defp importance_value(nil), do: nil
  defp importance_value(importance), do: importance * 1.0

  defp safe_status("active"), do: :active
  defp safe_status("superseded"), do: :superseded
  defp safe_status("candidate"), do: :candidate
end
