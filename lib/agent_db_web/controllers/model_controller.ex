defmodule AgentDbWeb.Controllers.ModelController do
  @moduledoc """
  What the store's models are doing, including a load in progress.

  Answerable while a model is downloading or loading, so a caller polling this
  can tell "still coming" from "not there".
  """
  use AgentDbWeb, :controller

  alias AgentDbWeb.Context

  def status(conn, _params) do
    json(conn, Context.model_status())
  end
end
