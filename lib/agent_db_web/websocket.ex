defmodule AgentDbWeb.WebSocket do
  @moduledoc """
  The WebSocket endpoint.

  Authentication happens here, at connect, because a socket that is open is a
  socket that has been let in: checking per call would mean an unauthenticated
  connection could hold resources and probe which calls exist.
  """
  use Phoenix.Socket

  channel("api:lobby", AgentDbWeb.Channel)

  transport(:websocket, Phoenix.Transports.WebSocket)

  @impl true
  def connect(params, _socket, _opts) do
    if AgentDb.Config.http_auth() do
      authenticate(params)
    else
      {:ok, %{user: "anonymous"}}
    end
  end

  @impl true
  def id(_socket), do: "agent_db_socket"

  defp authenticate(%{"authorization" => [token]}) do
    # Compared in full, so a token beginning with a valid one is not accepted.
    if token in AgentDb.Config.http_auth_tokens() do
      {:ok, %{user: "api_user"}}
    else
      {:error, :unauthorized}
    end
  end

  defp authenticate(_params), do: {:error, :unauthorized}
end
