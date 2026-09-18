defmodule AgentDbWeb.Controllers.ModelController do
  use AgentDbWeb, :controller
  alias AgentDbWeb.Context

  def status(conn, _params) do
    status = Context.model_status()
    json(conn, status)
  end
end