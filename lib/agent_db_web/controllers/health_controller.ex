defmodule AgentDbWeb.Controllers.HealthController do
  use AgentDbWeb, :controller
  alias AgentDbWeb.Context

  def show(conn, _params) do
    result = Context.health_check()
    status = if result.status == "ok", do: 200, else: 503
    conn
    |> put_status(status)
    |> json(result)
  end
end