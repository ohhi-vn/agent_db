defmodule AgentDbWeb.Endpoint do
  use AgentDbWeb, :endpoint

  socket "/api", AgentDb.WebSocket
  socket "/live", Phoenix.LiveView.Socket

  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:json, :urlencoded, :multipart],
    pass: ["*/*"],
    json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session,
    store: :cookie,
    key: "_agent_db_key",
    signing_salt: "agent_db_session_salt"
  plug AgentDbWeb.Router

  @impl true
  def init(_key, config) do
    {:ok, Keyword.put(config, :secret_key_base, "agent_db_dev_secret_key_base")}
  end
end