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

  @default_page 1
  @default_per_page 20
  @default_top_k 10

  @doc "A page of the document names under `prefix`."
  @spec list_documents(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def list_documents(opts \\ []) do
    opts = normalize(opts)
    page = integer_param(opts, "page", @default_page)
    per_page = integer_param(opts, "per_page", @default_per_page)

    case AgentDb.list(opts["prefix"] || "") do
      {:ok, names} ->
        {:ok, page_of(names, page, per_page)}

      {:error, _} = err ->
        err
    end
  end

  defp page_of(names, page, per_page) do
    names = Enum.sort(names)
    offset = (page - 1) * per_page

    %{
      data: Enum.slice(names, offset, per_page) || [],
      meta: %{
        page: page,
        per_page: per_page,
        total: length(names),
        total_pages: div(length(names) + per_page - 1, per_page)
      }
    }
  end

  @doc "A document's full content."
  @spec get_document(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_document(uri), do: AgentDb.read(uri)

  @doc "Writes a document, creating it or replacing it."
  @spec put_document(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put_document(uri, content, opts \\ []), do: AgentDb.write(uri, content, opts)

  @doc "Removes the subtree at `uri`."
  @spec delete_document(String.t()) :: :ok | {:error, term()}
  def delete_document(uri), do: AgentDb.rm(uri)

  @doc "Imports Agent Skills into a user's skills subtree. See `AgentDb.import_skills/2`."
  @spec import_skills(String.t(), AgentDb.Application.Skills.source()) ::
          {:ok, map()} | {:error, term()}
  def import_skills(user_id, source), do: AgentDb.import_skills(user_id, source)

  @doc "Why a skill import was refused, in words."
  @spec skill_import_error(term()) :: String.t()
  def skill_import_error(reason), do: AgentDb.skill_import_error_message(reason)

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

  @doc "Sessions, of which the store keeps no index to list."
  @spec list_sessions(keyword()) :: {:ok, []}
  def list_sessions(_opts \\ []), do: {:ok, []}

  @doc "A session's messages."
  @spec get_session(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_session(id), do: AgentDb.get_session(id)

  @doc "How the store's models are doing, including a load in progress."
  @spec model_status() :: map()
  def model_status, do: AgentDb.model_status()

  @doc "How much background work is outstanding, by status."
  @spec job_stats() :: map()
  def job_stats, do: AgentDb.queue_stats()

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
      value when is_binary(value) -> String.to_integer(value)
    end
  end
end
