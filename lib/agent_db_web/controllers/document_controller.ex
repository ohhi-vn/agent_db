defmodule AgentDbWeb.Controllers.DocumentController do
  use AgentDbWeb, :controller
  alias AgentDbWeb.Context

  def index(conn, params) do
    with {:ok, result} <- Context.list_documents(params) do
      json(conn, result)
    else
      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: reason})
    end
  end

  def show(conn, %{"id" => uri}) do
    with {:ok, content} <- Context.get_document(uri) do
      json(conn, %{uri: uri, content: content})
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})
      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: reason})
    end
  end

  def create(conn, %{"document" => params}) do
    uri = params["uri"]
    content = params["content"]
    opts = params["opts"] || []

    with {:ok, result} <- Context.create_document(uri, content, opts) do
      conn
      |> put_status(201)
      |> json(%{status: "created", uri: uri} |> Map.merge(result))
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason})
    end
  end

  def update(conn, %{"id" => uri, "document" => params}) do
    content = params["content"]
    opts = params["opts"] || []

    with {:ok, _} <- Context.update_document(uri, content, opts) do
      json(conn, %{status: "updated", uri: uri})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason})
    end
  end

  def delete(conn, %{"id" => uri}) do
    with :ok <- Context.delete_document(uri) do
      json(conn, %{status: "deleted", uri: uri})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason})
    end
  end
end