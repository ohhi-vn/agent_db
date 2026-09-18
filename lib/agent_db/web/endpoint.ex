defmodule AgentDb.WebEndpoint do
  @moduledoc """
  Phoenix endpoint for WebSocket transport.
  """

  use Phoenix.Endpoint, otp_app: :agent_db

  socket "/api", AgentDb.WebSocket

  @impl true
  def init(_key, config) do
    {:ok, Keyword.put(config, :secret_key_base, "agent_db_dev_secret_key_base")}
  end
end