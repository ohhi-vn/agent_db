defmodule AgentDb.WebSocket do
  @moduledoc """
  Phoenix WebSocket handler with channel routing.
  """

  use Phoenix.Socket

  ## Channels
  channel "api:lobby", AgentDb.WebChannel

  ## Transports
  transport :websocket, Phoenix.Transports.WebSocket

  @impl true
  def connect(%{"authorization" => [token]}, _socket, _opts) do
    if AgentDb.Config.http_auth() do
      valid_tokens = AgentDb.Config.http_auth_tokens()
      if token in valid_tokens do
        {:ok, %{user: "api_user"}}
      else
        {:error, :unauthorized}
      end
    else
      {:ok, %{user: "anonymous"}}
    end
  end

  def connect(_params, _socket, _opts) do
    if AgentDb.Config.http_auth() do
      {:error, :unauthorized}
    else
      {:ok, %{user: "anonymous"}}
    end
  end

  @impl true
  def id(_socket), do: "agent_db_socket"
end