defmodule AgentDb.Core.Transport do
  @moduledoc """
  An outer surface that exposes the store's public facade to a protocol.

  A transport is replaceable because it is the edge: it owns request parsing,
  authentication, rendering, and its own lifecycle, and it reaches the store
  only through the public `AgentDb` facade. It never touches storage or
  inference directly, so a store behaviour change does not ripple into wire
  formats and a transport change cannot alter what the store guarantees.

  A transport is optional. `enabled?/0` decides whether its children are
  composed at all, and `child_specs/1` supplies the rest.
  """

  @doc "Whether this transport is part of the current deployment."
  @callback enabled?() :: boolean()

  @doc "The supervised children this transport needs, in the order they must start."
  @callback child_specs(keyword()) :: [Supervisor.child_spec() | module()]
end
