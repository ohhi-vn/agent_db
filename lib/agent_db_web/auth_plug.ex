defmodule AgentDbWeb.AuthPlug do
  @moduledoc """
  Optional bearer-token authentication for the API.

  Off by default, and the surface it guards is unauthenticated by design when
  it is off: it exposes document and memory content, session identifiers and
  model state, so the listener binds loopback unless a deployment asks for
  more. Turning this on is a separate decision from reaching the port at all.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias AgentDb.Config

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Config.http_auth() do
      with {:ok, token} <- bearer_token(conn),
           :ok <- authorize(token, Config.http_auth_tokens()) do
        conn
      else
        {:error, :unauthorized} -> unauthorized(conn)
      end
    else
      conn
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _other -> {:error, :unauthorized}
    end
  end

  # A configured token is compared in full rather than by prefix, so a token
  # that begins with a valid one is not accepted.
  defp authorize(token, permitted) when is_list(permitted) do
    if token in permitted, do: :ok, else: {:error, :unauthorized}
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
