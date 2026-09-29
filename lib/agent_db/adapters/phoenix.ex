defmodule AgentDb.Adapters.Phoenix do
  @moduledoc false

  # The default transport: the HTTP and WebSocket surface, built on Phoenix.
  #
  # It is an edge, so it owns everything about being an edge -- parsing a
  # request, authenticating it, rendering an answer, and serving the endpoint --
  # and reaches the store only through the `AgentDb` facade. A transport that
  # read the database or asked the model manager directly would put wire
  # concerns inside the store's guarantees, and a store change would ripple
  # into every protocol it happened to be written into.

  @behaviour AgentDb.Core.Transport

  @impl true
  def enabled?, do: AgentDb.Config.http_enabled()

  @impl true
  def child_specs(_opts), do: [{AgentDbWeb.Endpoint, []}]
end
