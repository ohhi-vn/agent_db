defmodule AgentDbWeb.Plugs.AuthPlug do
  @moduledoc """
  Bearer token authentication for API endpoints.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias AgentDb.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    if Config.http_auth() do
      case get_bearer_token(conn) do
        nil -> unauthorized(conn)
        token -> 
          if token in Config.http_auth_tokens() do
            conn
          else
            unauthorized(conn)
          end
      end
    else
      conn
    end
  end

  defp get_bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> (fn h -> Regex.run(~r/Bearer\s+(.+)/, h) end).()
    |> (fn [_, token] -> token end).()
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> put_resp_header("www-authenticate", "Bearer")
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end