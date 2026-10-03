defmodule AgentDbWeb.McpTest do
  @moduledoc """
  The MCP surface's contract: handshake, tool inventory, facade mapping,
  JSON-safe errors, auth, and trace handling.
  """
  # The JSON-RPC error codes below are protocol identifiers, not magnitudes:
  # `-32601` is "method not found", and writing it `-32_601` would read as a
  # quantity. The check stays on everywhere else.
  # credo:disable-for-this-file Credo.Check.Readability.LargeNumbers
  use ExUnit.Case, async: false

  alias AgentDbWeb.Mcp

  @port 41_199

  setup do
    original = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

    originals =
      for key <- ~w(AGENT_DB_HTTP_ENABLED AGENT_DB_HTTP_AUTH AGENT_DB_HTTP_AUTH_TOKENS),
          into: %{},
          do: {key, System.get_env(key)}

    on_exit(fn ->
      Application.put_env(:agent_db, AgentDbWeb.Endpoint, original)
      for {key, value} <- originals, do: restore_env(key, value)
      :ok = restart_app()
    end)

    :ok
  end

  describe "handshake and inventory" do
    test "initialize answers with protocol version and server info" do
      response =
        Mcp.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, [])

      assert %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "protocolVersion" => version,
                 "capabilities" => _,
                 "serverInfo" => %{"name" => "agent-db"}
               }
             } = response

      assert is_binary(version)
    end

    test "tools/list exposes the full read-write inventory" do
      response =
        Mcp.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, [])

      names = response["result"]["tools"] |> Enum.map(& &1["name"])

      for expected <- ~w(context_read context_write context_rm context_list context_tree
                         context_search context_find context_grep memory_recall memory_remember
                         memory_forget session_create session_append session_get session_commit
                         store_health) do
        assert expected in names, "missing tool #{expected}"
      end
    end

    test "unknown method is a JSON-RPC error, not a crash" do
      response = Mcp.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "nope"}, [])

      assert %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32601, "message" => _}} =
               response
    end

    test "malformed request is an invalid-request error" do
      assert %{"error" => %{"code" => -32600}} = Mcp.handle_request(%{"bogus" => true}, [])
    end
  end

  describe "facade mapping" do
    test "write then read round-trips content" do
      uri = "viking://resources/mcp/roundtrip.md"

      assert %{"result" => _} =
               call("context_write", %{"uri" => uri, "content" => "hello mcp"})

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]}} =
               call("context_read", %{"uri" => uri})

      assert %{"uri" => ^uri, "content" => "hello mcp"} = Jason.decode!(text)
    end

    test "list, tree, find, and grep reach the store" do
      uri = "viking://resources/mcp/discoverable.md"
      assert %{"result" => _} = call("context_write", %{"uri" => uri, "content" => "needle line"})

      assert %{"result" => %{"content" => [%{"text" => list_text}]}} =
               call("context_list", %{"uri" => "viking://resources/mcp"})

      assert %{"names" => names} = Jason.decode!(list_text)
      assert "discoverable.md" in names

      assert %{"result" => %{"content" => [%{"text" => tree_text}]}} =
               call("context_tree", %{"uri" => "viking://resources/mcp", "depth" => 2})

      assert is_map(Jason.decode!(tree_text))

      assert %{"result" => %{"content" => [%{"text" => find_text}]}} =
               call("context_find", %{"term" => "discoverable"})

      assert [%{"uri" => ^uri} | _] = Jason.decode!(find_text)["results"]

      assert %{"result" => %{"content" => [%{"text" => grep_text}]}} =
               call("context_grep", %{"term" => "needle line"})

      assert [%{"uri" => ^uri} | _] = Jason.decode!(grep_text)["results"]
    end

    test "keyword search answers with results" do
      uri = "viking://resources/mcp/searchable.md"

      assert %{"result" => _} =
               call("context_write", %{"uri" => uri, "content" => "mcp-search-token"})

      assert %{"result" => %{"content" => [%{"text" => text}]}} =
               call("context_search", %{"term" => "mcp-search-token", "mode" => "keyword"})

      uris = text |> Jason.decode!() |> Map.fetch!("results") |> Enum.map(& &1["uri"])
      assert uri in uris
    end

    test "memory remember, recall, and forget" do
      uri = "viking://user/memories/preferences/mcp_tool"

      assert %{"result" => _} =
               call("memory_remember", %{"uri" => uri, "value" => "prefers mcp"})

      assert %{"result" => %{"content" => [%{"text" => recall_text}]}} =
               call("memory_recall", %{"uri" => uri})

      assert [%{"value" => "prefers mcp"}] = Jason.decode!(recall_text)["memories"]

      assert %{"result" => _} = call("memory_forget", %{"uri" => uri})

      assert %{"result" => %{"content" => [%{"text" => after_text}]}} =
               call("memory_recall", %{"uri" => uri})

      assert [] = Jason.decode!(after_text)["memories"]
    end

    test "session create, append, get, and commit" do
      assert %{"result" => %{"content" => [%{"text" => create_text}]}} =
               call("session_create", %{})

      %{"session_id" => id} = Jason.decode!(create_text)

      assert %{"result" => _} =
               call("session_append", %{
                 "session_id" => id,
                 "role" => "user",
                 "content" => "hi"
               })

      assert %{"result" => %{"content" => [%{"text" => get_text}]}} =
               call("session_get", %{"session_id" => id})

      assert [%{"content" => "hi"}] = Jason.decode!(get_text)["messages"]

      dest = "viking://resources/mcp/session-#{id}.md"

      assert %{"result" => %{"content" => [%{"text" => commit_text}]}} =
               call("session_commit", %{"session_id" => id, "destination_uri" => dest})

      assert %{"result" => ^dest} = Jason.decode!(commit_text)
    end

    test "rm removes what write created" do
      uri = "viking://resources/mcp/doomed.md"
      assert %{"result" => _} = call("context_write", %{"uri" => uri, "content" => "x"})
      assert %{"result" => _} = call("context_rm", %{"uri" => uri})
      assert %{"error" => _} = call("context_read", %{"uri" => uri})
    end

    test "store_health answers with health, models, and queue" do
      assert %{"result" => %{"content" => [%{"text" => text}]}} = call("store_health", %{})
      body = Jason.decode!(text)
      assert Map.has_key?(body, "health")
      assert Map.has_key?(body, "models")
      assert Map.has_key?(body, "queue")
    end
  end

  describe "errors stay JSON-safe and the session stays usable" do
    test "an unservable call returns a string message and the next call succeeds" do
      assert %{
               "error" => %{"code" => code, "message" => message, "data" => %{"reason" => reason}}
             } =
               call("context_search", %{"term" => "x", "mode" => "bogus-mode"})

      assert is_integer(code)
      assert is_binary(message)
      assert is_binary(reason)

      assert %{"result" => %{"tools" => _}} =
               Mcp.handle_request(
                 %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
                 []
               )
    end

    test "missing arguments and unknown tools are JSON errors with string messages" do
      assert %{"error" => %{"code" => -32000, "message" => "missing_argument"}} =
               call("context_read", %{})

      assert %{"error" => %{"code" => code, "message" => message}} =
               Mcp.handle_request(
                 %{
                   "jsonrpc" => "2.0",
                   "id" => 3,
                   "method" => "tools/call",
                   "params" => %{"name" => "nope", "arguments" => %{}}
                 },
                 []
               )

      assert is_integer(code)
      assert is_binary(message)
    end
  end

  describe "HTTP auth and trace on /mcp" do
    test "a request with no token is refused when auth is on" do
      configure_auth("true", "secret")

      assert {:ok, 401, %{"error" => "unauthorized"}} = post_mcp(%{"method" => "tools/list"})
    end

    test "a configured token is accepted and trace context preserves the shape" do
      configure_auth("true", "secret")

      assert {:ok, 200, body} =
               post_mcp(%{"method" => "tools/list"},
                 token: "secret",
                 traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
               )

      assert %{"result" => %{"tools" => [_ | _]}} = body
      refute Map.has_key?(body, "trace")
    end

    test "requests are unauthenticated when auth is off" do
      configure_auth("false", "")

      assert {:ok, 200, %{"result" => %{"tools" => [_ | _]}}} =
               post_mcp(%{"method" => "tools/list"})
    end
  end

  defp call(name, args, id \\ 1) do
    Mcp.handle_request(
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      },
      []
    )
  end

  defp start_listener do
    Application.put_env(
      :agent_db,
      AgentDbWeb.Endpoint,
      Keyword.put(
        Application.get_env(:agent_db, AgentDbWeb.Endpoint, []),
        :http,
        Keyword.put(http_config(), :port, @port) |> Keyword.put(:ip, {127, 0, 0, 1})
      )
    )

    System.put_env("AGENT_DB_HTTP_ENABLED", "true")
    :ok = restart_app()
  end

  defp configure_auth(enabled, tokens) do
    System.put_env("AGENT_DB_HTTP_AUTH", enabled)
    System.put_env("AGENT_DB_HTTP_AUTH_TOKENS", tokens)
    start_listener()
  end

  defp http_config do
    :agent_db |> Application.get_env(AgentDbWeb.Endpoint, []) |> Keyword.get(:http, [])
  end

  defp post_mcp(payload, opts \\ []) do
    body = Map.merge(%{"jsonrpc" => "2.0", "id" => 1}, payload) |> Jason.encode!()

    headers =
      [
        {"host", "127.0.0.1"},
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
      ] ++
        if(token = opts[:token], do: [{"authorization", "Bearer #{token}"}], else: []) ++
        if trace = opts[:traceparent], do: [{"traceparent", trace}], else: []

    head =
      ["POST /mcp HTTP/1.1" | Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)]
      |> Enum.join("\r\n")

    case :gen_tcp.connect({127, 0, 0, 1}, @port, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          :ok = :gen_tcp.send(socket, head <> "\r\n\r\n" <> body)
          read_response(socket, "")
        after
          :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :refused
    end
  end

  defp read_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data
        response(acc) || read_response(socket, acc)

      {:error, _reason} ->
        {:ok, nil, %{}}
    end
  end

  defp response(acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, _body] -> response(acc, head)
      [_partial] -> nil
    end
  end

  defp response(acc, head) do
    status = head |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    [_head, body] = String.split(acc, "\r\n\r\n", parts: 2)

    {:ok, status, decode_body(body)}
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"body" => body}
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
