defmodule AgentDb.McpTest do
  @moduledoc """
  The core MCP surface's contract: tool inventory, direct in-process
  invocation, and JSON-RPC envelope handling, without HTTP.
  """
  # The JSON-RPC error codes below are protocol identifiers, not magnitudes.
  # credo:disable-for-this-file Credo.Check.Readability.LargeNumbers
  use ExUnit.Case, async: false

  alias AgentDb.Mcp

  setup do
    :ok
  end

  describe "tool inventory" do
    test "tools/0 exposes the full inventory" do
      names = Mcp.tools() |> Enum.map(& &1["name"])

      for expected <- ~w(context_read context_abstract context_overview context_layers
                         context_write context_rm context_list context_tree context_search
                         context_find context_grep memory_recall memory_remember memory_forget
                         memory_candidates memory_promote memory_reject session_create
                         session_append session_get session_commit store_health) do
        assert expected in names, "missing tool #{expected}"
      end
    end

    test "each tool carries name, description, and inputSchema" do
      for tool <- Mcp.tools() do
        assert is_binary(tool["name"])
        assert is_binary(tool["description"])
        assert is_map(tool["inputSchema"])
      end
    end
  end

  describe "JSON-RPC envelope" do
    test "initialize answers with protocol version and server info" do
      response =
        Mcp.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, [])

      assert %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "protocolVersion" => version,
                 "serverInfo" => %{"name" => "agent-db"}
               }
             } = response

      assert is_binary(version)
    end

    test "tools/list returns the inventory" do
      response =
        Mcp.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, [])

      names = response["result"]["tools"] |> Enum.map(& &1["name"])
      assert "context_read" in names
    end

    test "unknown method is a JSON-RPC error" do
      response = Mcp.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "nope"}, [])

      assert %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601}} = response
    end

    test "malformed request is an invalid-request error" do
      assert %{"error" => %{"code" => -32600}} = Mcp.handle_request(%{"bogus" => true}, [])
    end
  end

  describe "direct in-process invocation" do
    test "call_tool reads a written document" do
      uri = "viking://resources/mcp/core_roundtrip.md"

      assert {:ok, %{"uri" => ^uri, "status" => "ok"}} =
               Mcp.call_tool("context_write", %{"uri" => uri, "content" => "hello core"})

      assert {:ok, %{"uri" => ^uri, "content" => "hello core"}} =
               Mcp.call_tool("context_read", %{"uri" => uri})
    end

    test "call_tool returns missing-argument error" do
      assert {:error, {:missing_argument, "uri"}} = Mcp.call_tool("context_read", %{})
    end

    test "call_tool returns unknown-tool error" do
      assert {:error, {:unknown_tool, "nope"}} = Mcp.call_tool("nope", %{})
    end

    test "call_tool store_health answers" do
      assert {:ok, %{"health" => _, "models" => _, "queue" => _}} =
               Mcp.call_tool("store_health", %{})
    end
  end

  describe "JSON-RPC and direct path agree" do
    test "tools/call returns the same data as call_tool" do
      uri = "viking://resources/mcp/agree.md"
      {:ok, _} = Mcp.call_tool("context_write", %{"uri" => uri, "content" => "agree"})

      {:ok, data} = Mcp.call_tool("context_read", %{"uri" => uri})

      response =
        Mcp.handle_request(
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => "context_read", "arguments" => %{"uri" => uri}}
          },
          []
        )

      assert %{"result" => %{"content" => [%{"text" => text}]}} = response
      assert Jason.decode!(text) == data
    end
  end
end
