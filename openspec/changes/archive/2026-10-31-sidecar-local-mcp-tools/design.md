# Design

## Context

The MCP tool inventory and its JSON-RPC envelope handling currently live in `lib/agent_db_web/mcp.ex` (`AgentDbWeb.Mcp`), which sits in the Phoenix web layer and is reached through `AgentDbWeb.Controllers.McpController`. The dispatch itself is a pure mapping from tool name to the `AgentDb` facade plus argument validation, option translation, and trace propagation; nothing in it requires HTTP, auth, or Phoenix. See `proposal.md` for motivation.

## Goals / Non-Goals

**Goals:**
- Move tool definitions and dispatch into a core module `AgentDb.Mcp` that compiles without the web layer being booted.
- Expose `tools/0`, `call_tool/3`, and `handle_request/2` from the core module.
- Keep `AgentDbWeb.Mcp` working as a compatibility shim and keep the HTTP endpoint's behavior identical.
- Keep the change additive: no facade, schema, or remote-contract changes.

**Non-Goals:**
- Changing tool names, schemas, or result shapes.
- Removing Phoenix/HTTP support or making the web layer optional at the dependency level.
- Adding a new transport or a host-side MCP SDK adapter.
- Auto-disabling HTTP defaults for non-test environments (hosts set `http_enabled: false` explicitly).

## Decisions

### 1. Core module location: `lib/agent_db/mcp.ex` (`AgentDb.Mcp`)

The tool layer is a store-facing adapter, not web-facing logic, so it belongs in the core application rather than under `agent_db_web`. It may call `AgentDb` and `AgentDb.Observability` directly; it must not reference `AgentDbWeb`, `Plug`, or `Phoenix`.

Alternatives considered:
- Keep it in `AgentDbWeb.Mcp` and add a separate thin wrapper: rejected, because the dispatch would still live in the web layer, contradicting the sidecar goal.
- Put it under `AgentDb.Adapters`: rejected; adapters implement ports, while this is a tool inventory over the facade, not a port implementation.

### 2. Direct invocation API: `call_tool(name, args, opts \\ [])`

`call_tool/3` runs the same `dispatch/3` used by `handle_request/2` but returns `{:ok, data} | {:error, reason}` instead of building a JSON-RPC response. `handle_request/2` becomes a thin envelope around `call_tool/3`: it calls dispatch, then wraps the result into the JSON-RPC `result`/`error` shape. This guarantees the two paths cannot drift.

`args` is a map (string keys, matching the wire format). `opts` carries `:trace_context` and any future per-call options. Return values are the raw Elixir terms produced by dispatch (e.g. `%{"uri" => uri, "content" => content}`), not JSON strings.

### 3. Error contract for `call_tool/3`

- `{:error, :model_loading}` is returned verbatim for deferred loads.
- Other store errors return `{:error, reason}` with the same classified reason the remote endpoint puts in `data.reason`.
- Unknown tool returns `{:error, {:unknown_tool, name}}`.
- Missing required argument returns `{:error, {:missing_argument, key}}`.

This mirrors the remote path's classification without inventing new error classes.

### 4. Compatibility shim `AgentDbWeb.Mcp`

Rather than deleting `AgentDbWeb.Mcp`, it becomes a module that `defdelegate`s `tools/0`, `handle_request/2`, and `call_tool/3` to `AgentDb.Mcp`. This keeps existing tests, controllers, and any external callers working. The shim contains no dispatch logic, satisfying the single-source requirement. A future release may remove it with a deprecation notice.

### 5. HTTP controller

`AgentDbWeb.Controllers.McpController.handle/2` changes its `Mcp` alias from `AgentDbWeb.Mcp` to `AgentDb.Mcp` (or keeps the shim; behavior is identical). Trace opts extraction stays in the controller. No other controller changes.

### 6. Sidecar startup and configuration

No startup changes are required: `AgentDb.Application.start/2` already gates the transport on `AgentDb.Runtime.transport().enabled?()`, which checks `http_enabled`. The design relies on this existing gate and documents that sidecar hosts set `http_enabled: false` (via config or `AGENT_DB_HTTP_ENABLED=false`) to avoid binding a port. `put_default_config/0` continues to apply defaults, so a host that does nothing gets the daemon defaults (HTTP on) — documented, not changed, to avoid surprising standalone users.

### 7. Documentation

- `guides/API-REFERENCE.md`: add a section for `AgentDb.Mcp` (tools/0, call_tool/3, handle_request/2) and a sidecar usage example.
- `guides/ARCHITECTURE.md`: note that the tool inventory is a core module reached by both the HTTP edge and in-process callers.
- `guides/SETUP.md` or `guides/USAGE.md`: sidecar quickstart (dep, config, start, invoke).

## Risks / Trade-offs

- [Risk] Moving the module breaks callers that pattern-match on `AgentDbWeb.Mcp` as a module name. → Mitigation: retain the shim with `defdelegate`, and update in-repo callers/tests to `AgentDb.Mcp` gradually; shim stays indefinitely.
- [Risk] `AgentDb.Mcp` referencing `AgentDbWeb.Context` (role translation) couples core to web-named module. → Mitigation: `AgentDbWeb.Context.role/1` is a pure helper; either move it into `AgentDb` (preferred) or keep the dependency as a utility module. Design prefers moving the pure helper to `AgentDb.Context` / keeping a small utility in core; if not feasible, keep the reference but document it. (Resolve during implementation.)
- [Risk] Tests reference `AgentDbWeb.Mcp` and may assert web-layer coupling. → Mitigation: retarget primary tests to `AgentDb.Mcp`; keep a small compatibility test for the shim.
- [Risk] `call_tool/3` returning raw terms could tempt callers to depend on internal shapes. → Mitigation: document that shapes mirror the remote contract and are stable.

## Migration Plan

1. Create `lib/agent_db/mcp.ex` by moving the body of `lib/agent_db_web/mcp.ex`.
2. Replace the original module's body with `defdelegate` shims.
3. Update `McpController` alias.
4. Update tests to target `AgentDb.Mcp`; add sidecar-focused tests.
5. Update guides and API reference.
6. Run `mix test`, `mix credo --strict`, `mix dialyzer`.

Rollback: revert the move; the shim keeps external callers working throughout, so partial rollback is safe.

## Open Questions

- Whether to move `AgentDbWeb.Context.role/1` into core or keep a dependency from `AgentDb.Mcp` on a web-named utility module. Resolve during implementation without changing specs.