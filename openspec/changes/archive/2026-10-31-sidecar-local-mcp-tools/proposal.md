# Proposal

## Why

AgentDb is already packaged and documented as a library that a host application starts with `Application.ensure_all_started(:agent_db)`, but its MCP tool layer lives entirely under `AgentDbWeb` and speaks JSON-RPC over HTTP. A host Elixir application that embeds AgentDb as a sidecar therefore has no in-process way to discover or invoke those tools: it must either stand up the HTTP endpoint (and pull Phoenix into the request path) or reimplement the dispatch mapping itself. That forces a network round-trip for work that is already in the same BEAM VM and makes AgentDb a poor first-class tool provider for in-process agents.

## What Changes

- Extract the MCP tool inventory and dispatch into a core, web-independent module (`AgentDb.Mcp`), so tool definitions and invocation no longer require the Phoenix web layer or an HTTP listener.
- Add a direct in-process entry point (`AgentDb.Mcp.call_tool/3`) returning `{:ok, term()} | {:error, reason}` without JSON-RPC encoding, HTTP, or a network round-trip, with the same data and error semantics (including `:model_loading`) as the remote endpoint.
- Preserve `handle_request/2` (JSON-RPC) and the `POST /mcp` HTTP endpoint by delegating to the core module, so remote clients, auth, and trace handling behave unchanged.
- Retain `AgentDbWeb.Mcp` as a thin compatibility shim delegating to `AgentDb.Mcp`, so existing callers and tests keep working.
- Document sidecar startup and local tool invocation (configuration keys, `http_enabled: false`, example usage) in the guides and API reference.

No breaking changes: the public facade (`AgentDb`), SQLite schema, and remote MCP/HTTP contracts are unchanged.

## Capabilities

### New Capabilities

- `sidecar`: running AgentDb as an embedded sidecar in a host Elixir application and invoking its MCP tool inventory directly in-process.

### Modified Capabilities

None.

## Impact

- Affected code: `lib/agent_db_web/mcp.ex` (extract to `lib/agent_db/mcp.ex`), `lib/agent_db_web/controllers/mcp_controller.ex` (delegate), `guides/API-REFERENCE.md`, `guides/ARCHITECTURE.md`, and a sidecar section in `guides/SETUP.md` or `guides/USAGE.md`.
- Tests: `test/agent_db_web/mcp_test.exs` (retargeted to the core module) plus new core-level tests for `tools/0` and `call_tool/3`.
- APIs: additive `AgentDb.Mcp.tools/0`, `AgentDb.Mcp.call_tool/3`, `AgentDb.Mcp.handle_request/2`; `AgentDbWeb.Mcp` retained as a shim.
- Dependencies: no new dependencies.