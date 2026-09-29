defmodule AgentDbWeb.Controllers.DocumentController do
  @moduledoc """
  Documents over HTTP.

  Renders what the store answers and nothing more: a URI that is not there is a
  404, a request the store cannot serve is a 422 with the reason it gave, and
  anything else is a 500 for the transport to log rather than a store detail
  handed to a client.
  """
  use AgentDbWeb, :controller

  alias AgentDbWeb.Context

  def index(conn, params) do
    case Context.list_documents(params) do
      {:ok, page} -> json(conn, page)
      {:error, _reason} -> server_error(conn)
    end
  end

  def show(conn, %{"id" => uri}) do
    case Context.get_document(uri) do
      {:ok, content} -> json(conn, %{uri: uri, content: content})
      {:error, :not_found} -> not_found(conn)
      {:error, _reason} -> server_error(conn)
    end
  end

  def create(conn, %{"document" => %{"uri" => uri, "content" => content} = params}) do
    case Context.put_document(uri, content, document_opts(params)) do
      :ok -> conn |> put_status(201) |> json(%{status: "created", uri: uri})
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  def update(conn, %{"id" => uri, "document" => %{"content" => content} = params}) do
    case Context.put_document(uri, content, document_opts(params)) do
      :ok -> json(conn, %{status: "updated", uri: uri})
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  def delete(conn, %{"id" => uri}) do
    case Context.delete_document(uri) do
      :ok -> json(conn, %{status: "deleted", uri: uri})
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  # The layers a caller supplies are the store's, not the transport's, so they
  # are named here and passed through as the store's own options.
  defp document_opts(%{"opts" => opts}) when is_map(opts) do
    for {key, value} <- opts, key in ["async", "sync_timeout_ms", "abstract", "overview"] do
      {String.to_existing_atom(key), value}
    end
  end

  defp document_opts(_params), do: []

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp unprocessable(conn, reason),
    do: conn |> put_status(422) |> json(%{error: describe(reason)})

  defp server_error(conn), do: conn |> put_status(500) |> json(%{error: "internal_server_error"})

  # A reason is rendered as something JSON can hold. An atom or string is used
  # as it is; a tagged reason keeps its tag, which is the part a client acts
  # on.
  defp describe(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp describe({tag, _detail}) when is_atom(tag), do: tag
  defp describe(reason), do: inspect(reason)
end
