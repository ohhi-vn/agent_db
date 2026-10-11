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
          overview: String.t() | nil,
          enabled: boolean(),
          group_tag: String.t()
        }

  @doc "Fetches one node by URI."
  @spec get(SQLite.conn(), String.t()) :: {:ok, node_row() | nil} | {:error, term()}
  def get(conn, uri) do
    case SQLite.query_one(
           conn,
           "SELECT uri, parent_uri, name, kind, content, abstract, overview, enabled, group_tag FROM nodes WHERE uri = ?1",
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
           "SELECT uri, parent_uri, name, kind, content, abstract, overview, enabled, group_tag FROM nodes WHERE parent_uri = ?1 ORDER BY name",
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
    case exists?(conn, uri) do
      {:ok, true} -> SQLite.transaction(conn, fn c -> purge_subtree(c, uri) end)
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

  # Vec tables only exist when sqlite-vec loaded. Every dim table plus legacy
  # `vec_nodes` is purged so a removed URI leaves rows in none of them.
  defp delete_vec_nodes(conn, uri, prefix) do
    if SQLite.vec_available?(conn) do
      case SQLite.list_vec_dims(conn) do
        {:ok, dims} ->
          Enum.reduce_while(dims, :ok, fn dim, :ok ->
            case SQLite.exec_write(
                   conn,
                   "DELETE FROM \"#{SQLite.vec_table(dim)}\" WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
                   [uri, prefix]
                 ) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)
          |> case do
            :ok -> delete_legacy_vec_nodes(conn, uri, prefix)
            {:error, _} = err -> err
          end

        {:error, _} = err ->
          err
      end
    else
      :ok
    end
  end

  defp delete_legacy_vec_nodes(conn, uri, prefix) do
    case SQLite.query_one(
           conn,
           "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'vec_nodes'",
           []
         ) do
      {:ok, [1]} ->
        SQLite.exec_write(
          conn,
          "DELETE FROM vec_nodes WHERE uri = ?1 OR uri LIKE ?2 ESCAPE '\\'",
          [uri, prefix]
        )

      _ ->
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

  Bounded by `limit` in SQL and ordered by URI, so the two are the same on
  every call: a store cannot return a different set of the same results just
  because the rows came back in a different order.
  """
  @spec search(SQLite.conn(), String.t(), String.t() | nil, pos_integer()) ::
          {:ok, [node_row()]} | {:error, term()}
  def search(conn, term, scope_prefix, limit) do
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
           "SELECT uri, parent_uri, name, kind, content, abstract, overview, enabled, group_tag FROM nodes WHERE " <>
             where <> " ORDER BY uri ASC LIMIT ?",
           args ++ [limit]
         ) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_node/1)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Path-discovery matches for `query` within `scope_uri` or beneath it.

  Matches the URI path (excluding the `viking://` scheme) as a
  case-insensitive literal substring. Scope membership is
  exact-URI-or-descendant. Results are ordered by URI with at most `limit`
  entries.
  """
  @spec find_paths(SQLite.conn(), String.t(), String.t() | nil, pos_integer()) ::
          {:ok, [%{uri: String.t(), name: String.t(), kind: kind()}]} | {:error, term()}
  def find_paths(conn, query, scope_uri, limit) do
    pattern = "%" <> like_escape(String.downcase(query)) <> "%"

    {scope_where, scope_args} = scope_predicate(scope_uri)

    sql =
      "SELECT uri, parent_uri, name, kind, enabled, group_tag FROM nodes WHERE lower(substr(uri, 10)) LIKE ? ESCAPE '\\'" <>
        scope_where <> " ORDER BY uri ASC LIMIT ?"

    case SQLite.query(conn, sql, [pattern | scope_args] ++ [limit]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [uri, _parent_uri, name, kind, enabled, group_tag] ->
           %{
             uri: uri,
             name: name,
             kind: safe_kind(kind),
             enabled: enabled != 0,
             group_tag: group_tag || ""
           }
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Line matches for `query` in full document content (L2) within `scope_uri`
  or beneath it.

  Only L2 content matches; abstracts and overviews never do. Scope
  membership is exact-URI-or-descendant. Results are ordered by URI then
  one-based line number with at most `limit` entries, each excerpt
  containing the match and at most 280 characters.
  """
  @spec grep_content(SQLite.conn(), String.t(), String.t() | nil, pos_integer()) ::
          {:ok, [%{uri: String.t(), line_number: pos_integer(), excerpt: String.t()}]}
          | {:error, term()}
  def grep_content(conn, query, scope_uri, limit) do
    pattern = "%" <> like_escape(String.downcase(query)) <> "%"

    {scope_where, scope_args} = scope_predicate(scope_uri)

    sql =
      "SELECT uri, content, enabled FROM nodes WHERE kind = 'doc' AND lower(COALESCE(content, '')) LIKE ? ESCAPE '\\'" <>
        scope_where <> " ORDER BY uri ASC LIMIT ?"

    case SQLite.query(conn, sql, [pattern | scope_args] ++ [limit]) do
      {:ok, rows} ->
        {:ok, line_hits(rows, query, limit)}

      {:error, _} = err ->
        err
    end
  end

  # Exact-URI-or-descendant, so `scope` never matches a sibling like
  # `scope-old`. A `nil` scope matches everything.
  defp scope_predicate(nil), do: {"", []}

  defp scope_predicate(scope_uri) do
    {" AND (uri = ? OR uri LIKE ? ESCAPE '\\')",
     [scope_uri, like_escape(scope_uri <> "/") <> "%"]}
  end

  defp line_hits(rows, query, limit) do
    needle = String.downcase(query)
    needle_len = String.length(query)

    rows
    |> Enum.flat_map(fn
      [uri, content] ->
        matching_lines(uri, content || "", needle, needle_len, true)

      [uri, content, enabled] ->
        matching_lines(uri, content || "", needle, needle_len, enabled != 0)
    end)
    |> Enum.take(limit)
  end

  defp matching_lines(uri, content, needle, needle_len, enabled) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.contains?(String.downcase(line), needle) end)
    |> Enum.map(fn {line, n} ->
      %{uri: uri, line_number: n, excerpt: excerpt(line, needle, needle_len), enabled: enabled}
    end)
  end

  @doc false
  @spec excerpt(String.t(), String.t(), non_neg_integer()) :: String.t()
  def excerpt(line, needle_down, needle_len) do
    if String.length(line) <= 280 do
      line
    else
      downcased = String.downcase(line)

      index =
        case String.split(downcased, needle_down, parts: 2) do
          [before, _rest] -> String.length(before)
          [_only] -> 0
        end

      start = max(0, index - div(280 - needle_len, 2))
      String.slice(line, start, 280)
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
      overview: overview,
      enabled: true,
      group_tag: ""
    }
  end

  defp row_to_node([uri, parent_uri, name, kind, content, abstract, overview, enabled, group_tag]) do
    %{
      uri: uri,
      parent_uri: parent_uri,
      name: name,
      kind: safe_kind(kind),
      content: content,
      abstract: abstract,
      overview: overview,
      enabled: enabled != 0,
      group_tag: group_tag || ""
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

  # -- composition counts (read-only, for the operator console) --

  @doc "How many nodes there are of each kind."
  @spec counts(SQLite.conn()) ::
          {:ok, %{documents: non_neg_integer(), directories: non_neg_integer()}}
  def counts(conn) do
    case SQLite.query(conn, "SELECT kind, COUNT(*) FROM nodes GROUP BY kind", []) do
      {:ok, rows} ->
        {:ok,
         %{
           documents: count_of(rows, "doc"),
           directories: count_of(rows, "dir")
         }}

      {:error, _} = err ->
        err
    end
  end

  # One grouped query rather than a walk: the first path segment after the
  # scheme is the top-level subtree, and `substr` already yields "" for a
  # node held directly at the root.
  @doc "Document counts per top-level subtree, as `%{segment => count}`."
  @spec count_by_top_subtree(SQLite.conn()) :: {:ok, %{optional(String.t()) => non_neg_integer()}}
  def count_by_top_subtree(conn) do
    sql = """
    SELECT CASE WHEN length(substr(uri, 10)) = 0 THEN '' ELSE substr(uri, 10, instr(substr(uri, 10) || '/', '/') - 1) END,
           COUNT(*)
    FROM nodes WHERE kind = 'doc' GROUP BY 1
    """

    case SQLite.query(conn, sql, []) do
      {:ok, rows} -> {:ok, Map.new(rows, fn [segment, count] -> {segment, count} end)}
      {:error, _} = err -> err
    end
  end

  # Exact-URI-or-descendant, so counting a subtree cannot pick up a sibling
  # named `project-old`. Directories are not documents.
  @doc "How many documents are at `prefix` or beneath it."
  @spec count_documents(SQLite.conn(), String.t()) :: non_neg_integer()
  def count_documents(conn, prefix) do
    sql = """
    SELECT COUNT(*) FROM nodes
    WHERE kind = 'doc' AND (uri = ?1 OR uri LIKE ?2 ESCAPE '\\')
    """

    case SQLite.query_one(conn, sql, [prefix, like_escape(prefix <> "/") <> "%"]) do
      {:ok, [count]} -> count
      _ -> 0
    end
  end

  defp count_of(rows, kind) do
    case Enum.find(rows, fn [row_kind, _count] -> row_kind == kind end) do
      [_kind, count] -> count
      nil -> 0
    end
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

  # -- enable/disable and grouping metadata --

  @group_tag_max 64

  @doc """
  Validates an operator-assigned group tag. Empty clears the tag.
  Tags are 1..64 chars of letters, digits, dash, underscore, or slash.
  """
  @spec validate_group(String.t()) :: :ok | {:error, {:invalid_group, String.t()}}
  def validate_group(""), do: :ok

  def validate_group(tag) when is_binary(tag) do
    if String.length(tag) >= 1 and String.length(tag) <= @group_tag_max and
         Regex.match?(~r/\A[A-Za-z0-9_\-\/]+\z/, tag) do
      :ok
    else
      {:error, {:invalid_group, tag}}
    end
  end

  def validate_group(tag), do: {:error, {:invalid_group, tag}}

  @doc """
  Sets `enabled` for the subtree at `uri` (node and descendants) in one
  statement. Returns `:not_found` when nothing is stored there.
  """
  @spec set_enabled(SQLite.conn(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(conn, uri, enabled) when is_boolean(enabled) do
    case exists?(conn, uri) do
      {:ok, true} ->
        SQLite.exec_write(
          conn,
          "UPDATE nodes SET enabled = ?1, updated_at = ?2 WHERE uri = ?3 OR uri LIKE ?4 ESCAPE '\\'",
          [
            if(enabled, do: 1, else: 0),
            System.system_time(:millisecond),
            uri,
            like_escape(uri <> "/") <> "%"
          ]
        )

      {:ok, false} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Sets `group_tag` for the subtree at `uri` (node and descendants) in one
  statement. Empty clears the tag. Returns `:not_found` when absent and
  `{:invalid_group, tag}` for illegal tags.
  """
  @spec set_group(SQLite.conn(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_group(conn, uri, tag) when is_binary(tag) do
    with :ok <- validate_group(tag),
         {:ok, true} <- exists?(conn, uri) do
      SQLite.exec_write(
        conn,
        "UPDATE nodes SET group_tag = ?1, updated_at = ?2 WHERE uri = ?3 OR uri LIKE ?4 ESCAPE '\\'",
        [tag, System.system_time(:millisecond), uri, like_escape(uri <> "/") <> "%"]
      )
    else
      {:ok, false} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc "The stored enabled/group state for one node, or `{:ok, nil}` when absent."
  @spec node_meta(SQLite.conn(), String.t()) ::
          {:ok, %{enabled: boolean(), group_tag: String.t()} | nil} | {:error, term()}
  def node_meta(conn, uri) do
    case SQLite.query_one(conn, "SELECT enabled, group_tag FROM nodes WHERE uri = ?1", [uri]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, [enabled, group_tag]} -> {:ok, %{enabled: enabled != 0, group_tag: group_tag || ""}}
      {:error, _} = err -> err
    end
  end

  # -- recursive operations listing --

  @type list_filter :: %{
          optional(:substring) => String.t(),
          optional(:include_disabled) => boolean(),
          optional(:group) => String.t()
        }

  @doc """
  Recursive document URIs under `scope` in deterministic order, paged.

  Returns `{rows, total}` where rows carry `uri`, `enabled`, and `group_tag`
  without blobs. `opts` supports `:substring` (literal, case-insensitive),
  `:include_disabled` (default false), and `:group` (custom tag exact or
  top-level subtree segment).
  """
  @spec list_all_documents(SQLite.conn(), String.t(), pos_integer(), pos_integer(), list_filter()) ::
          {:ok, {[map()], non_neg_integer()}} | {:error, term()}
  def list_all_documents(conn, scope, limit, offset, filter \\ %{}) do
    {where, args} = list_all_where(scope, filter)

    count_sql = "SELECT COUNT(*) FROM nodes WHERE #{where}"

    with {:ok, [total]} <- SQLite.query_one(conn, count_sql, args),
         {:ok, rows} <-
           SQLite.query(
             conn,
             "SELECT uri, enabled, group_tag FROM nodes WHERE #{where} ORDER BY uri ASC LIMIT ? OFFSET ?",
             args ++ [limit, offset]
           ) do
      {:ok,
       {Enum.map(rows, fn [uri, enabled, group_tag] ->
          %{uri: uri, enabled: enabled != 0, group_tag: group_tag || ""}
        end), total}}
    end
  end

  defp list_all_where("viking://" = _scope, filter) do
    base = "kind = 'doc'"
    args = []
    {base, args} = apply_enabled_where(base, args, filter)
    {base, args} = apply_substring_where(base, args, filter)
    apply_group_where(base, args, filter)
  end

  defp list_all_where(scope, filter) do
    base = "kind = 'doc' AND (uri = ? OR uri LIKE ? ESCAPE '\\')"
    args = [scope, like_escape(scope <> "/") <> "%"]

    {base, args} = apply_enabled_where(base, args, filter)
    {base, args} = apply_substring_where(base, args, filter)
    apply_group_where(base, args, filter)
  end

  defp apply_enabled_where(where, args, %{include_disabled: true}), do: {where, args}

  defp apply_enabled_where(where, args, _filter), do: {"#{where} AND enabled = 1", args}

  defp apply_substring_where(where, args, %{substring: sub}) when is_binary(sub) and sub != "" do
    pattern = "%" <> like_escape(String.downcase(sub)) <> "%"
    {"#{where} AND lower(uri) LIKE ? ESCAPE '\\'", args ++ [pattern]}
  end

  defp apply_substring_where(where, args, _filter), do: {where, args}

  defp apply_group_where(where, args, %{group: group}) when is_binary(group) and group != "" do
    # Custom tag exact, or top-level subtree segment as implicit group.
    {"#{where} AND (group_tag = ? OR uri LIKE ? ESCAPE '\\' OR uri = ?)",
     args ++ [group, like_escape("viking://" <> group <> "/") <> "%", "viking://" <> group]}
  end

  defp apply_group_where(where, args, _filter), do: {where, args}

  # -- installed-skill inventory --

  @type skill_entry :: %{
          name: String.t(),
          owner: String.t(),
          uri: String.t(),
          enabled: boolean(),
          group_tag: String.t()
        }

  @doc """
  Skill roots (`viking://user/{owner}/skills/{name}` dirs) in URI order, paged.

  Supports `:substring` (name/URI, case-insensitive), `:owner` (exact
  `user_id`), `:include_disabled`, and `:group` (owner exact or custom tag
  exact). Returns `{entries, total}` without file contents.
  """
  @spec list_skill_roots(SQLite.conn(), pos_integer(), pos_integer(), map()) ::
          {:ok, {[skill_entry()], non_neg_integer()}} | {:error, term()}
  def list_skill_roots(conn, limit, offset, filter \\ %{}) do
    {where, args} = skill_roots_where(filter)
    count_sql = "SELECT COUNT(*) FROM nodes WHERE #{where}"

    with {:ok, [total]} <- SQLite.query_one(conn, count_sql, args),
         {:ok, rows} <-
           SQLite.query(
             conn,
             "SELECT uri, enabled, group_tag FROM nodes WHERE #{where} ORDER BY uri ASC LIMIT ? OFFSET ?",
             args ++ [limit, offset]
           ) do
      {:ok, {Enum.map(rows, &skill_entry/1), total}}
    end
  end

  # A skill root is a dir exactly four segments deep under user skills:
  # `viking://` (2 slashes) plus `user/{owner}/skills/{name}` (3 more).
  defp skill_roots_where(filter) do
    base =
      "kind = 'dir' AND uri LIKE 'viking://user/%/skills/%' ESCAPE '\\' AND (LENGTH(uri) - LENGTH(REPLACE(uri, '/', ''))) = 5"

    args = []
    {base, args} = apply_skill_owner_where(base, args, filter)
    {base, args} = apply_enabled_where(base, args, filter)
    {base, args} = apply_skill_substring_where(base, args, filter)
    apply_skill_group_where(base, args, filter)
  end

  defp apply_skill_owner_where(where, args, %{owner: owner})
       when is_binary(owner) and owner != "" do
    {"#{where} AND uri LIKE ? ESCAPE '\\'",
     args ++ [like_escape("viking://user/" <> owner <> "/skills/") <> "%"]}
  end

  defp apply_skill_owner_where(where, args, _filter), do: {where, args}

  defp apply_skill_substring_where(where, args, %{substring: sub})
       when is_binary(sub) and sub != "" do
    pattern = "%" <> like_escape(String.downcase(sub)) <> "%"
    {"#{where} AND lower(uri) LIKE ? ESCAPE '\\'", args ++ [pattern]}
  end

  defp apply_skill_substring_where(where, args, _filter), do: {where, args}

  defp apply_skill_group_where(where, args, %{group: group})
       when is_binary(group) and group != "" do
    {"#{where} AND (group_tag = ? OR uri LIKE ? ESCAPE '\\')",
     args ++ [group, like_escape("viking://user/" <> group <> "/skills/") <> "%"]}
  end

  defp apply_skill_group_where(where, args, _filter), do: {where, args}

  defp skill_entry([uri, enabled, group_tag]) do
    case String.split(String.replace_prefix(uri, "viking://", ""), "/") do
      ["user", owner, "skills", name] ->
        %{name: name, owner: owner, uri: uri, enabled: enabled != 0, group_tag: group_tag || ""}

      _ ->
        %{name: uri, owner: "", uri: uri, enabled: enabled != 0, group_tag: group_tag || ""}
    end
  end

  @doc "How many documents sit at `uri` or beneath it (file count for one skill)."
  @spec count_subtree_documents(SQLite.conn(), String.t()) :: non_neg_integer()
  def count_subtree_documents(conn, uri) do
    case SQLite.query_one(
           conn,
           "SELECT COUNT(*) FROM nodes WHERE kind = 'doc' AND (uri = ?1 OR uri LIKE ?2 ESCAPE '\\')",
           [uri, like_escape(uri <> "/") <> "%"]
         ) do
      {:ok, [count]} -> count
      _ -> 0
    end
  end
end
