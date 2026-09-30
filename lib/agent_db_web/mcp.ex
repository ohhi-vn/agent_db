defmodule AgentDbWeb.Mcp do
  @moduledoc """
  The MCP tool inventory over the store facade.

  Pure mapping: tool names and JSON-RPC envelope handling live here so they
  are testable without HTTP. The controller is a thin wrapper that adds
  authentication (via the `:api` pipeline) and trace extraction.
  """

  alias AgentDb
  alias AgentDb.Observability

  @protocol_version "2024-11-05"
  @server_name "agent-db"
  @server_version "0.1.0"

  @doc "The MCP tool inventory served by `tools/list`."
  @spec tools() :: [map()]
  def tools do
    [
      tool(
        "context_read",
        "Reads a document's full content (L2).",
        %{
          "uri" => %{"type" => "string"}
        },
        ["uri"]
      ),
      tool(
        "context_write",
        "Writes a document, creating missing parents.",
        %{
          "uri" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        ["uri", "content"]
      ),
      tool(
        "context_rm",
        "Removes the subtree at a URI.",
        %{
          "uri" => %{"type" => "string"}
        },
        ["uri"]
      ),
      tool(
        "context_list",
        "Lists the direct children of a URI.",
        %{
          "uri" => %{"type" => "string"}
        },
        ["uri"]
      ),
      tool(
        "context_tree",
        "Depth-limited projection of the tree at a URI.",
        %{
          "uri" => %{"type" => "string"},
          "depth" => %{"type" => "integer"}
        },
        ["uri"]
      ),
      tool(
        "context_search",
        "Searches by keyword, vector, or hybrid.",
        %{
          "term" => %{"type" => "string"},
          "mode" => %{"type" => "string"},
          "scope" => %{"type" => "string"},
          "top_k" => %{"type" => "integer"}
        },
        ["term"]
      ),
      tool(
        "context_find",
        "Discovers paths by literal substring.",
        %{
          "term" => %{"type" => "string"},
          "scope" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
        },
        ["term"]
      ),
      tool(
        "context_grep",
        "Inspects L2 content lines by literal substring.",
        %{
          "term" => %{"type" => "string"},
          "scope" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
        },
        ["term"]
      ),
      tool(
        "memory_recall",
        "Reads memories back by URI, type, or term.",
        %{
          "uri" => %{"type" => "string"},
          "type" => %{"type" => "string"},
          "term" => %{"type" => "string"},
          "include_superseded" => %{"type" => "boolean"}
        },
        []
      ),
      tool(
        "memory_remember",
        "Records a durable fact as a memory.",
        %{
          "uri" => %{"type" => "string"},
          "value" => %{"type" => "string"},
          "confidence" => %{"type" => "number"},
          "source" => %{"type" => "string"}
        },
        ["uri", "value"]
      ),
      tool(
        "memory_forget",
        "Removes a memory and its provenance.",
        %{
          "uri" => %{"type" => "string"}
        },
        ["uri"]
      ),
      tool("session_create", "Creates a session and returns its id.", %{}, []),
      tool(
        "session_append",
        "Appends a message to a session.",
        %{
          "session_id" => %{"type" => "string"},
          "role" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        ["session_id", "role", "content"]
      ),
      tool(
        "session_get",
        "Returns every message of a session, in order.",
        %{
          "session_id" => %{"type" => "string"}
        },
        ["session_id"]
      ),
      tool(
        "session_commit",
        "Commits a session into the tree at a URI.",
        %{
          "session_id" => %{"type" => "string"},
          "destination_uri" => %{"type" => "string"}
        },
        ["session_id", "destination_uri"]
      ),
      tool("store_health", "Store health, model status, and queue depth.", %{}, [])
    ]
  end

  @doc """
  Handles one JSON-RPC request map.

  Returns a response map with `jsonrpc: "2.0"`. `opts` may carry
  `:trace_context` propagated to store operations that accept it.
  """
  @spec handle_request(map(), keyword()) :: map()
  def handle_request(%{"method" => "initialize", "id" => id}, _opts) do
    result(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => @server_name, "version" => @server_version}
    })
  end

  def handle_request(%{"method" => "tools/list", "id" => id}, _opts) do
    result(id, %{"tools" => tools()})
  end

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => params}, opts)
      when is_map(params) do
    case params do
      %{"name" => name} when is_binary(name) ->
        args = if is_map(params["arguments"]), do: params["arguments"], else: %{}
        call_tool(id, name, args, opts)

      _ ->
        error(id, -32602, "invalid params: tools/call requires a tool name")
    end
  end

  def handle_request(%{"method" => "tools/call", "id" => id}, _opts) do
    error(id, -32602, "invalid params: tools/call requires params")
  end

  def handle_request(%{"method" => method, "id" => id}, _opts) when is_binary(method) do
    error(id, -32601, "method not found: #{method}")
  end

  def handle_request(_request, _opts) do
    error(nil, -32600, "invalid request")
  end

  defp call_tool(id, name, args, opts) do
    case dispatch(name, args, opts) do
      {:ok, data} ->
        result(id, %{"content" => [%{"type" => "text", "text" => Jason.encode!(data)}]})

      {:error, :model_loading} ->
        error(id, -32_001, "model_loading")

      {:error, reason} ->
        error(id, -32_000, render_message(reason), %{
          "reason" => Observability.error_code(reason)
        })
    end
  end

  defp dispatch("context_read", args, _opts) do
    with {:ok, uri} <- required(args, "uri") do
      case AgentDb.read(uri) do
        {:ok, content} -> {:ok, %{"uri" => uri, "content" => content}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_write", args, opts) do
    with {:ok, uri} <- required(args, "uri"),
         {:ok, content} <- required(args, "content") do
      write_opts =
        []
        |> put_opt(:abstract, args["abstract"])
        |> put_opt(:overview, args["overview"])
        |> put_trace(opts)

      case AgentDb.write(uri, content, write_opts) do
        :ok -> {:ok, %{"uri" => uri, "status" => "ok"}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_rm", args, _opts) do
    with {:ok, uri} <- required(args, "uri") do
      case AgentDb.rm(uri) do
        :ok -> {:ok, %{"uri" => uri, "status" => "ok"}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_list", args, _opts) do
    with {:ok, uri} <- required(args, "uri") do
      case AgentDb.list(uri) do
        {:ok, names} -> {:ok, %{"uri" => uri, "names" => names}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_tree", args, _opts) do
    with {:ok, uri} <- required(args, "uri") do
      case AgentDb.tree(uri, integer_arg(args["depth"], 2)) do
        {:ok, tree} -> {:ok, %{"uri" => uri, "tree" => tree}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_search", args, opts) do
    with {:ok, term} <- required(args, "term") do
      search_opts =
        [mode: search_mode(args["mode"])]
        |> put_opt(:scope, args["scope"])
        |> put_opt(:top_k, integer_arg(args["top_k"], nil))
        |> put_trace(opts)

      case AgentDb.search(term, search_opts) do
        {:ok, results} -> {:ok, %{"results" => results}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_find", args, opts) do
    with {:ok, term} <- required(args, "term") do
      find_opts =
        []
        |> put_opt(:scope, args["scope"])
        |> put_opt(:limit, integer_arg(args["limit"], nil))
        |> put_trace(opts)

      case AgentDb.find(term, find_opts) do
        {:ok, results} -> {:ok, %{"results" => results}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("context_grep", args, opts) do
    with {:ok, term} <- required(args, "term") do
      grep_opts =
        []
        |> put_opt(:scope, args["scope"])
        |> put_opt(:limit, integer_arg(args["limit"], nil))
        |> put_trace(opts)

      case AgentDb.grep(term, grep_opts) do
        {:ok, results} -> {:ok, %{"results" => results}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("memory_recall", args, _opts) do
    recall_opts =
      []
      |> put_opt(:uri, args["uri"])
      |> put_opt(:type, args["type"])
      |> put_opt(:term, args["term"])
      |> put_opt(:include_superseded, args["include_superseded"])

    case AgentDb.recall(recall_opts) do
      {:ok, memories} -> {:ok, %{"memories" => memories}}
      {:error, _} = err -> err
    end
  end

  defp dispatch("memory_remember", args, _opts) do
    with {:ok, uri} <- required(args, "uri"),
         {:ok, value} <- required(args, "value") do
      remember_opts =
        []
        |> put_opt(:confidence, args["confidence"])
        |> put_opt(:source, args["source"])

      case AgentDb.remember(uri, value, remember_opts) do
        {:ok, stored} -> {:ok, %{"uri" => stored, "status" => "ok"}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("memory_forget", args, _opts) do
    with {:ok, uri} <- required(args, "uri") do
      case AgentDb.forget(uri) do
        :ok -> {:ok, %{"uri" => uri, "status" => "ok"}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("session_create", _args, _opts) do
    case AgentDb.create_session() do
      {:ok, session_id} -> {:ok, %{"session_id" => session_id}}
      {:error, _} = err -> err
    end
  end

  defp dispatch("session_append", args, _opts) do
    with {:ok, session_id} <- required(args, "session_id"),
         {:ok, role} <- required(args, "role"),
         {:ok, content} <- required(args, "content") do
      case AgentDb.append_message(session_id, append_role(role), content) do
        :ok -> {:ok, %{"session_id" => session_id, "status" => "ok"}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("session_get", args, _opts) do
    with {:ok, session_id} <- required(args, "session_id") do
      case AgentDb.get_session(session_id) do
        {:ok, messages} -> {:ok, %{"session_id" => session_id, "messages" => messages}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("session_commit", args, _opts) do
    with {:ok, session_id} <- required(args, "session_id"),
         {:ok, destination} <- required(args, "destination_uri") do
      case AgentDb.commit_session(session_id, destination) do
        {:ok, result} -> {:ok, %{"result" => result}}
        {:error, _} = err -> err
      end
    end
  end

  defp dispatch("store_health", _args, _opts) do
    {:ok,
     %{
       "health" => AgentDb.health_check(),
       "models" => AgentDb.model_status(),
       "queue" => AgentDb.queue_stats()
     }}
  end

  defp dispatch(name, _args, _opts), do: {:error, {:unknown_tool, name}}

  defp tool(name, description, properties, required) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required
      }
    }
  end

  defp result(id, data), do: %{"jsonrpc" => "2.0", "id" => id, "result" => data}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp error(id, code, message, data),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    }

  defp required(args, key) do
    case args[key] do
      nil -> {:error, {:missing_argument, key}}
      "" -> {:error, {:missing_argument, key}}
      value -> {:ok, value}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_trace(opts, parent) do
    case Keyword.get(parent, :trace_context) do
      %{trace_id: _, span_id: _} = ctx -> Keyword.put(opts, :trace_context, ctx)
      _ -> opts
    end
  end

  defp integer_arg(nil, default), do: default
  defp integer_arg(value, _default) when is_integer(value) and value > 0, do: value
  defp integer_arg(_value, default), do: default

  defp search_mode(nil), do: :keyword
  defp search_mode("keyword"), do: :keyword
  defp search_mode("vector"), do: :vector
  defp search_mode("hybrid"), do: :hybrid
  defp search_mode(other), do: other

  defp append_role("user"), do: :user
  defp append_role("assistant"), do: :assistant
  defp append_role("system"), do: :system
  defp append_role(_other), do: :unknown

  # Store errors share the taxonomy message every other transport renders:
  # the classified tag only, never details that may carry URIs or content.
  defp render_message(reason), do: Observability.error_message(reason)
end
