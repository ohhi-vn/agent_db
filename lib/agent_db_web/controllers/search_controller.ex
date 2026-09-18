defmodule AgentDbWeb.Controllers.SearchController do
  use AgentDbWeb, :controller
  alias AgentDbWeb.Context

  def search(conn, params) do
    term = params["term"]
    opts = %{
      "mode" => params["mode"] || "keyword",
      "top_k" => params["top_k"] || "10"
    }

    with {:ok, results} <- Context.search_documents(term, opts) do
      json(conn, %{results: results})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason})
    end
  end

  def suggest(conn, params) do
    term = params["term"]
    
    # Simple prefix-based suggestions from document list
    with {:ok, %{data: docs}} <- Context.list_documents(%{"prefix" => term, "per_page" => 10}) do
      suggestions = Enum.map(docs, & &1)
      json(conn, %{suggestions: suggestions})
    else
      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: reason})
    end
  end
end