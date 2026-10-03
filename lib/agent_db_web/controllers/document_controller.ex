defmodule AgentDbWeb.Controllers.DocumentController do
  @moduledoc """
  Documents over HTTP.

  Renders what the store answers and nothing more: a URI that is not there is a
  404, a request the store cannot serve is a 422 with the reason it gave, and
  anything else is a 500 for the transport to log rather than a store detail
  handed to a client.
  """
  use AgentDbWeb, :controller

  alias AgentDb.Observability
  alias AgentDbWeb.Context

  def index(conn, params) do
    case Context.list_documents(params) do
      {:ok, page} -> json(conn, page)
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def show(conn, %{"id" => uri}) do
    case Context.get_document(uri) do
      {:ok, content} -> json(conn, %{uri: uri, content: content})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def create(conn, %{"document" => %{"uri" => uri, "content" => content} = params}) do
    case Context.put_document(uri, content, with_trace(document_opts(params), conn)) do
      :ok -> conn |> put_status(201) |> json(%{status: "created", uri: uri})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def update(conn, %{"id" => uri, "document" => %{"content" => content} = params}) do
    case Context.put_document(uri, content, with_trace(document_opts(params), conn)) do
      :ok -> json(conn, %{status: "updated", uri: uri})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def delete(conn, %{"id" => uri}) do
    case Context.delete_document(uri) do
      :ok -> json(conn, %{status: "deleted", uri: uri})
      {:error, reason} -> Context.transport_error(conn, reason)
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

  defp with_trace(opts, conn) do
    case Observability.from_conn(conn) do
      nil -> opts
      ctx -> Keyword.put(opts, :trace_context, ctx)
    end
  end
end
