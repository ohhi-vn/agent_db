defmodule AgentDb.SidecarTest do
  @moduledoc """
  Smoke test for running AgentDb as an embedded sidecar: the store starts
  without an HTTP listener and tools are invocable in-process.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Mcp

  test "store is usable in-process with HTTP disabled" do
    assert Mcp.tools() != []

    uri = "viking://resources/sidecar/smoke.md"

    assert {:ok, %{"uri" => ^uri, "status" => "ok"}} =
             Mcp.call_tool("context_write", %{"uri" => uri, "content" => "sidecar smoke"})

    assert {:ok, %{"uri" => ^uri, "content" => "sidecar smoke"}} =
             Mcp.call_tool("context_read", %{"uri" => uri})
  end
end
