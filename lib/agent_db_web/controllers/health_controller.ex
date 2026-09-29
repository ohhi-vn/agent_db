defmodule AgentDbWeb.Controllers.HealthController do
  @moduledoc """
  Liveness, as the store reports it.

  A degraded store still answers -- documents, keyword search, sessions and
  memories all work without a model -- so a 503 here means something a monitor
  can act on rather than a dead process.
  """
  use AgentDbWeb, :controller

  alias AgentDbWeb.Context

  def show(conn, _params) do
    result = Context.health_check()

    conn
    |> put_status(if(result.status == "ok", do: 200, else: 503))
    |> json(result)
  end
end
