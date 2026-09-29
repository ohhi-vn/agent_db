defmodule AgentDbWeb.SessionAuth do
  @moduledoc """
  Authentication for the browser surface.

  The browser surface is a console for a store that is already local to the
  process embedding it: it serves an operator's own documents, to an operator
  on the machine the store runs on. There is therefore no user to
  authenticate, and this plug deliberately passes every request through.

  A deployment that puts a real identity in front of the console should put it
  in front of the endpoint, not have this plug grow a notion of a user.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: conn
end
