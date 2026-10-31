defmodule AgentDbWeb.Mcp do
  @moduledoc """
  Compatibility shim over `AgentDb.Mcp`.

  The MCP tool inventory now lives in the core module `AgentDb.Mcp` so it can
  be used in-process by a sidecar host without the Phoenix web layer. This
  module delegates to it, keeping existing callers and tests working.
  """

  @doc "The MCP tool inventory served by `tools/list`."
  @spec tools() :: [map()]
  def tools, do: AgentDb.Mcp.tools()

  @doc "Invokes a tool by name in-process, delegating to `AgentDb.Mcp`."
  @spec call_tool(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call_tool(name, args \\ %{}, opts \\ []), do: AgentDb.Mcp.call_tool(name, args, opts)

  @doc "Handles one JSON-RPC request map, delegating to `AgentDb.Mcp`."
  @spec handle_request(map(), keyword()) :: map()
  def handle_request(request, opts \\ []), do: AgentDb.Mcp.handle_request(request, opts)
end
