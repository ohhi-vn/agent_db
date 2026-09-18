defmodule AgentDb.WebChannel do
  @moduledoc """
  Phoenix Channel for WebSocket API.
  
  Handles incoming requests and routes them to AgentDb functions.
  """

  use Phoenix.Channel

  alias AgentDb.Config

  @impl true
  def join("api:lobby", _params, socket) do
    # Optional authentication
    if Config.http_auth() do
      # In a real implementation, you'd validate a token from socket.assigns
      # For now, allow all connections if auth is enabled but no token provided
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_in("v1.write", %{"uri" => uri, "content" => content, "opts" => opts}, socket) do
    case AgentDb.write(uri, content, opts) do
      :ok ->
        {:reply, {:ok, %{status: "ok"}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.read", %{"uri" => uri}, socket) do
    case AgentDb.read(uri) do
      {:ok, content} ->
        {:reply, {:ok, %{content: content}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.abstract", %{"uri" => uri}, socket) do
    case AgentDb.abstract(uri) do
      {:ok, abstract} ->
        {:reply, {:ok, %{abstract: abstract}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.overview", %{"uri" => uri}, socket) do
    case AgentDb.overview(uri) do
      {:ok, overview} ->
        {:reply, {:ok, %{overview: overview}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.list", %{"uri" => uri}, socket) do
    case AgentDb.list(uri) do
      {:ok, names} ->
        {:reply, {:ok, %{names: names}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.tree", %{"uri" => uri, "depth" => depth}, socket) do
    case AgentDb.tree(uri, depth) do
      {:ok, tree} ->
        {:reply, {:ok, %{tree: tree}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.rm", %{"uri" => uri}, socket) do
    case AgentDb.rm(uri) do
      :ok ->
        {:reply, {:ok, %{status: "ok"}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.search", %{"term" => term, "opts" => opts}, socket) do
    case AgentDb.search(term, opts) do
      {:ok, results} ->
        {:reply, {:ok, %{results: results}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.create_session", _params, socket) do
    case AgentDb.create_session() do
      {:ok, session_id} ->
        {:reply, {:ok, %{session_id: session_id}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.append_message", %{"session_id" => session_id, "role" => role, "content" => content}, socket) do
    case AgentDb.append_message(session_id, String.to_existing_atom(role), content) do
      :ok ->
        {:reply, {:ok, %{status: "ok"}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.get_session", %{"session_id" => session_id}, socket) do
    case AgentDb.get_session(session_id) do
      {:ok, messages} ->
        {:reply, {:ok, %{messages: messages}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.commit_session", %{"session_id" => session_id, "destination_uri" => destination_uri, "opts" => opts}, socket) do
    case AgentDb.commit_session(session_id, destination_uri, opts) do
      {:ok, result} ->
        {:reply, {:ok, %{result: result}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("v1.model_status", _params, socket) do
    {:reply, {:ok, AgentDb.ML.ModelManager.model_status()}, socket}
  end

  # Catch-all for unknown events
  def handle_in(event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event", event: event}}, socket}
  end
end