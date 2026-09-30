defmodule AgentDbWeb.Controllers.McpController do
  @moduledoc """
  MCP Streamable HTTP endpoint.

  Authentication is enforced by the `:api` pipeline before this controller
  runs. Trace context is extracted from the `traceparent` header and passed
  to store operations that accept it; a missing or malformed header starts a
  new trace without changing auth, results, or response shapes.
  """
  use AgentDbWeb, :controller

  alias AgentDb.Observability
  alias AgentDbWeb.Mcp

  def handle(conn, params) do
    body = if is_map(params), do: Map.drop(params, ["controller", "action"]), else: %{}
    request = request_body(conn, body)
    opts = trace_opts(conn)

    conn
    |> put_resp_content_type("application/json")
    |> json(Mcp.handle_request(request, opts))
  end

  defp request_body(conn, body) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> body
      %{} = parsed when map_size(parsed) > 0 -> parsed
      _ -> body
    end
  end

  defp trace_opts(conn) do
    case Observability.from_conn(conn) do
      %{trace_id: _, span_id: _} = ctx -> [trace_context: ctx]
      _ -> []
    end
  end
end
