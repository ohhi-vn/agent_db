defmodule AgentDbWeb.CORSPlug do
  @moduledoc """
  CORS for the API.

  The surface is an agent's own context store, bound to loopback and read by
  local tooling, so the browsers that reach it are local too. The allowed
  origins are therefore configuration rather than a compiled-in list: a
  deployment that fronts this with a real gateway names its origins, and one
  that does not allows none.
  """
  @behaviour Plug

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, DELETE, OPTIONS"
  @allowed_headers "content-type, authorization"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case allowed_origin(conn) do
      nil -> conn
      origin -> allow(conn, origin)
    end
  end

  defp allowed_origin(conn) do
    origin = conn |> get_req_header("origin") |> List.first()

    # No Origin at all is not a cross-origin request, so there is nothing to
    # allow: a non-browser client is unaffected either way.
    if origin && origin in configured_origins() do
      origin
    end
  end

  defp configured_origins do
    :agent_db
    |> Application.get_env(:http_cors_origins, [])
    |> List.wrap()
  end

  defp allow(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
  end
end
