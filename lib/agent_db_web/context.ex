defmodule AgentDbWeb.Context do
  @moduledoc """
  The transport's view of the store.

  Everything here goes through the `AgentDb` facade. A request handler needs
  presentation -- a page of results, a status summary -- and not the machinery
  behind them, so this module shapes what the facade returns and stops there.
  Reading the database or the model manager from here would make the HTTP
  surface a second way into the store's internals, and a change to either would
  become a change to the wire.
  """
  alias AgentDb
  alias AgentDb.Observability

  @default_page 1
  @default_per_page 20
  @default_top_k 10

  # The console browses the whole store, and the tree root is the one URI that
  # is a valid listing scope for every document in it. Naming it is what makes
  # the total a real count rather than the zero an empty prefix produces.
  @tree_root "viking://"

  @doc "A page of the document names under `prefix`."
  @spec list_documents(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def list_documents(opts \\ []) do
    opts = normalize(opts)
    page = integer_param(opts, "page", @default_page)
    per_page = integer_param(opts, "per_page", @default_per_page)

    case AgentDb.list(opts["prefix"] || @tree_root) do
      {:ok, names} ->
        {:ok, page_of(names, page, per_page)}

      {:error, _} = err ->
        err
    end
  end

  # A page that is zero, negative, beyond the last one, or not a number at all is
  # clamped rather than refused: an operator clicking through a listing should
  # land on the nearest real page, not on a 500. Refusing would also make the
  # console depend on how the caller spelled the page.
  defp page_of(names, page, per_page) do
    names = Enum.sort(names)
    per_page = max(per_page, 1)
    total_pages = max(div(length(names) + per_page - 1, per_page), 1)
    page = page |> max(1) |> min(total_pages)
    offset = (page - 1) * per_page

    %{
      data: Enum.slice(names, offset, per_page),
      meta: %{
        page: page,
        per_page: per_page,
        total: length(names),
        total_pages: total_pages
      }
    }
  end

  @doc "A document's full content."
  @spec get_document(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_document(uri), do: AgentDb.read(uri)

  @doc """
  A document's LLM-facing layers with source and size.

  Returns `%{l0: layer, l1: layer, l2: layer}` where each layer is
  `%{text: String.t(), source: :stored | :fallback | :unavailable, chars: non_neg_integer()}`.
  L0 is what `AgentDb.abstract/1` returns, L1 what `AgentDb.overview/1`
  returns, L2 what `AgentDb.read/1` returns. A stored layer was persisted
  (caller-supplied or generated); a fallback was derived from L2 at read
  time; unavailable means the read failed. Read-only; never alters store
  state.
  """
  @spec get_layers(String.t()) :: %{l0: map(), l1: map(), l2: map()}
  def get_layers(uri) do
    stored =
      case AgentDb.stored_layers(uri) do
        {:ok, layers} -> layers
        {:error, _} -> %{abstract: nil, overview: nil}
      end

    %{
      l0: layer_entry(uri, &AgentDb.abstract/1, Map.get(stored, :abstract)),
      l1: layer_entry(uri, &AgentDb.overview/1, Map.get(stored, :overview)),
      l2: content_entry(uri)
    }
  end

  defp layer_entry(uri, read, stored_value) do
    case read.(uri) do
      {:ok, text} ->
        text = text || ""
        source = if is_binary(stored_value) and stored_value != "", do: :stored, else: :fallback
        %{text: text, source: source, chars: String.length(text)}

      {:error, _} ->
        %{text: "", source: :unavailable, chars: 0}
    end
  end

  defp content_entry(uri) do
    case AgentDb.read(uri) do
      {:ok, text} ->
        text = text || ""
        %{text: text, source: :stored, chars: String.length(text)}

      {:error, _} ->
        %{text: "", source: :unavailable, chars: 0}
    end
  end

  @doc "Writes a document, creating it or replacing it."
  @spec put_document(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put_document(uri, content, opts \\ []), do: AgentDb.write(uri, content, opts)

  @doc "Removes the subtree at `uri`."
  @spec delete_document(String.t()) :: :ok | {:error, term()}
  def delete_document(uri), do: AgentDb.rm(uri)

  @doc "Recursive paged document URIs under `scope` for operations listings."
  @spec list_all_documents(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def list_all_documents(opts \\ []) do
    opts = normalize(opts)
    scope = opts["scope"] || opts["prefix"] || @tree_root

    AgentDb.list_all_documents(scope,
      page: integer_param(opts, "page", @default_page),
      per_page: integer_param(opts, "per_page", @default_per_page),
      substring: to_string_param(opts, "substring", ""),
      include_disabled: truthy_param(opts, "include_disabled", false),
      group: to_string_param(opts, "group", "")
    )
  end

  @doc "Paged installed-skill inventory across users."
  @spec list_skills(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def list_skills(opts \\ []) do
    opts = normalize(opts)

    AgentDb.list_skills(
      page: integer_param(opts, "page", @default_page),
      per_page: integer_param(opts, "per_page", @default_per_page),
      substring: to_string_param(opts, "substring", ""),
      owner: to_string_param(opts, "owner", ""),
      include_disabled: truthy_param(opts, "include_disabled", false),
      group: to_string_param(opts, "group", "")
    )
  end

  @doc "Enables or disables the subtree at `uri`."
  @spec set_enabled(String.t(), boolean()) :: :ok | {:error, term()}
  def set_enabled(uri, enabled) when is_boolean(enabled), do: AgentDb.set_enabled(uri, enabled)

  @doc "Assigns the operator group tag for the subtree at `uri`. Empty clears."
  @spec set_group(String.t(), String.t()) :: :ok | {:error, term()}
  def set_group(uri, tag) when is_binary(tag), do: AgentDb.set_group(uri, tag)

  @doc "Bulk enable/disable over an explicit URI list."
  @spec bulk_set_enabled([String.t()], boolean()) :: {:ok, map()} | {:error, term()}
  def bulk_set_enabled(uris, enabled) when is_list(uris) and is_boolean(enabled),
    do: AgentDb.bulk_set_enabled(uris, enabled)

  @doc "Bulk group assignment over an explicit URI list."
  @spec bulk_set_group([String.t()], String.t()) :: {:ok, map()} | {:error, term()}
  def bulk_set_group(uris, tag) when is_list(uris) and is_binary(tag),
    do: AgentDb.bulk_set_group(uris, tag)

  @doc "Imports Agent Skills into a user's skills subtree. See `AgentDb.import_skills/2`."
  @spec import_skills(String.t(), AgentDb.Skills.Source.source()) ::
          {:ok, map()} | {:error, term()}
  def import_skills(user_id, source), do: AgentDb.import_skills(user_id, source)

  @doc "Why a skill import was refused, in words."
  @spec skill_import_error(term()) :: String.t()
  def skill_import_error(reason), do: AgentDb.skill_import_error_message(reason)

  @doc "Why a store operation failed, in words and from the shared taxonomy."
  @spec error_message(term()) :: String.t()
  def error_message(reason), do: Observability.error_message(reason)

  @doc "Searches the store. See `AgentDb.search/2` for the options."
  @spec search_documents(String.t(), map() | keyword()) :: {:ok, [map()]} | {:error, term()}
  def search_documents(term, opts \\ []) do
    opts = normalize(opts)

    # A mode arrives as the string the wire carries. Anything this transport
    # does not recognise is passed through as it arrived, so the store reports
    # it as an invalid mode rather than this module quietly substituting one.
    case AgentDb.search(term, search_options(opts)) do
      {:ok, results} -> {:ok, results}
      {:error, _} = err -> err
    end
  end

  # A limit arrives as a string when it came from a query parameter and as a
  # number when a caller passed one, so both are read the same way here rather
  # than each reaching the store as something it has to interpret.
  defp search_options(opts) do
    base = [mode: opts["mode"] || :keyword, top_k: top_k(opts)]
    base = with_scope(base, opts)

    case opts["trace_context"] do
      %{trace_id: _, span_id: _} = ctx -> Keyword.put(base, :trace_context, ctx)
      _ -> base
    end
  end

  # A scope arrives as the string the console carries. An empty scope is no
  # scope; anything else is passed through so the store validates it and
  # reports an invalid one rather than this module substituting for it.
  defp with_scope(base, opts) do
    case opts["scope"] do
      nil -> base
      "" -> base
      scope -> Keyword.put(base, :scope, scope)
    end
  end

  defp top_k(opts) do
    case opts["top_k"] do
      nil -> @default_top_k
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parsed_top_k(value)
      _other -> @default_top_k
    end
  end

  # A limit that is not a number is a bad request, not a reason to search
  # everything: falling back to the default would quietly answer a different
  # question than the one asked.
  defp parsed_top_k(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> limit
      _other -> @default_top_k
    end
  end

  @doc "A session's messages."
  @spec get_session(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_session(id), do: AgentDb.get_session(id)

  @doc "How the store's models are doing, including a load in progress."
  @spec model_status() :: map()
  def model_status, do: AgentDb.model_status()

  @doc "How much background work is outstanding, by status."
  @spec job_stats() :: map()
  def job_stats, do: AgentDb.queue_stats()

  @doc "How far behind the queue is, and which jobs are failing."
  @spec queue_detail(pos_integer()) :: map()
  def queue_detail(limit \\ 20), do: AgentDb.queue_detail(limit)

  @doc "What the store holds and how much room it takes on disk."
  @spec storage_stats() :: map()
  def storage_stats, do: AgentDb.storage_stats()

  @doc "The size of the store's disposable read caches."
  @spec cache_stats() :: map()
  def cache_stats, do: AgentDb.cache_stats()

  @doc "How much of the store's content each index covers."
  @spec index_coverage() :: map()
  def index_coverage, do: AgentDb.index_coverage()

  @doc "A bounded, read-only view of the BEAM runtime."
  @spec runtime_snapshot() :: map()
  def runtime_snapshot, do: snapshot_or_empty()

  @doc "Recent operational failures, newest first."
  @spec recent_errors(pos_integer()) :: [map()]
  def recent_errors(limit \\ 20), do: AgentDb.recent_errors(limit)

  @doc "Operation, job, and model counts by outcome."
  @spec operation_stats() :: map()
  def operation_stats, do: AgentDb.operation_stats()

  # A snapshot answers `{:ok, map}` or a classified error. A console section
  # that cannot be taken is a section saying so, not a section that takes the
  # console down with it.
  defp snapshot_or_empty do
    case AgentDb.runtime_snapshot() do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> %{error: :unavailable}
    end
  end

  @doc """
  Whether the store is usable, per check.

  A 200 or a 503 rather than an error: a store serving without a model is
  serving, and a monitor should be able to see which part is down.
  """
  @spec health_check() :: %{status: String.t(), checks: %{db: boolean(), models: boolean()}}
  def health_check, do: AgentDb.health_check()

  # A request's parameters arrive as a string-keyed map and a caller's own as a
  # keyword list. Both are read the same way here, so a caller passing either
  # gets the same answer.
  defp normalize(opts) when is_map(opts), do: opts
  defp normalize(opts) when is_list(opts), do: Map.new(opts)
  defp normalize(_opts), do: %{}

  defp integer_param(opts, key, default) do
    case opts[key] do
      nil -> default
      value when is_integer(value) -> value
      value when is_binary(value) -> Integer.parse(value, 10) |> parsed_int(default)
      _other -> default
    end
  end

  defp parsed_int({value, ""}, _default), do: value
  defp parsed_int({value, _rest}, _default), do: value
  defp parsed_int(:error, default), do: default

  defp to_string_param(opts, key, default) do
    case opts[key] do
      nil -> default
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> default
    end
  end

  defp truthy_param(opts, key, default) do
    case opts[key] do
      nil -> default
      true -> true
      false -> false
      "true" -> true
      "1" -> true
      "on" -> true
      _other -> false
    end
  end

  # A role arrives as the word the wire carries. One outside the set a session
  # holds is not turned into a term: an unrecognised role is a bad request, not
  # a reason to grow the vocabulary of stored rows.
  @doc "Maps a wire role to the atom the store writes, or `:unknown`."
  @spec role(String.t()) :: :user | :assistant | :system | :unknown
  def role("user"), do: :user
  def role("assistant"), do: :assistant
  def role("system"), do: :system
  def role(_other), do: :unknown

  # One rendering for every store error: status from the shared taxonomy, body
  # always JSON-safe with a machine-readable code, details never echoed.
  @doc "Renders a store error on a controller connection."
  @spec transport_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def transport_error(conn, reason) do
    conn
    |> Plug.Conn.put_status(Observability.http_status(reason))
    |> Phoenix.Controller.json(%{
      error: Observability.error_message(reason),
      code: Observability.error_code(reason)
    })
  end
end
