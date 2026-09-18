defmodule AgentDbWeb.Plugs.SessionAuth do
  @moduledoc """
  Session-based authentication for LiveView routes.
  Currently allows all access but can be extended.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    # For now, allow all. Can add session-based auth later.
    conn
  end
end