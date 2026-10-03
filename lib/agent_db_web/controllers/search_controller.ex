defmodule AgentDbWeb.Controllers.SearchController do
  @moduledoc """
  Search over HTTP.

  A search the store cannot serve -- an unknown mode, a model that is not
  available -- is a 422 carrying the reason, not a failure of the request
  itself.
  """
  use AgentDbWeb, :controller

  alias AgentDb.Observability
  alias AgentDbWeb.Context

  def search(conn, params) do
    term = params["term"]
    opts = %{"mode" => params["mode"], "top_k" => params["top_k"]}

    opts =
      case Observability.from_conn(conn) do
        nil -> opts
        ctx -> Map.put(opts, "trace_context", ctx)
      end

    case Context.search_documents(term, opts) do
      {:ok, results} -> json(conn, %{results: results})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def suggest(conn, params) do
    # Suggestions are the names already under a prefix, so this is a listing
    # rather than a search: what the caller wants to complete is a name, not a
    # document matched by content.
    case Context.list_documents(%{"prefix" => params["term"] || "", "per_page" => 10}) do
      {:ok, %{data: names}} -> json(conn, %{suggestions: names})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end
end
