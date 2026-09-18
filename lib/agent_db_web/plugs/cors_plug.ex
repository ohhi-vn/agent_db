defmodule AgentDbWeb.Plugs.CORSPlug do
  @moduledoc """
  CORS support for API endpoints.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()
    
    if origin && origin_allowed?(origin) do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    else
      conn
    end
  end

  defp origin_allowed?(_origin) do
    # For now allow all origins. Can be configured via Application config.
    true
  end
end