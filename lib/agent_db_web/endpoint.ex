defmodule AgentDbWeb.Endpoint do
  @moduledoc """
  The HTTP and WebSocket listener.

  Everything about being an endpoint -- which paths carry which protocol, how a
  body is parsed, how a session is signed -- belongs here, so that a change to
  the store's behaviour never has to be reflected in this file.
  """
  use AgentDbWeb, :endpoint

  socket("/api", AgentDbWeb.WebSocket)
  socket("/live", Phoenix.LiveView.Socket)

  # The console's compiled stylesheet and script, served from `priv/static`.
  # Without this plug the pages' `/assets/app.css` and `/assets/app.js` links
  # have no route and answer 404. It runs before the router and the session, so
  # public assets are served without the browser pipeline.
  plug(Plug.Static,
    at: "/",
    from: :agent_db,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)
  )

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json, :urlencoded, :multipart],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session,
    store: :cookie,
    key: "_agent_db_key",
    signing_salt: "agent_db_session_salt"
  )

  plug(AgentDbWeb.Router)
end
