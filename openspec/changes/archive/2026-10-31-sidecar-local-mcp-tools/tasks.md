# Tasks

## 1. Extract core MCP module

- [x] 1.1 Create `lib/agent_db/mcp.ex` (`AgentDb.Mcp`) by moving the tool inventory, dispatch, helpers, and JSON-RPC envelope handling from `lib/agent_db_web/mcp.ex`, and verify `mix compile` succeeds with the new module present.
- [x] 1.2 Add `AgentDb.Mcp.call_tool/3` returning `{:ok, term()} | {:error, reason}` by extracting the dispatch result from `handle_request/2`, and verify a unit test calling `call_tool("context_read", %{"uri" => uri})` returns the same data as the facade.
- [x] 1.3 Refactor `handle_request/2` to delegate to `call_tool/3` for `tools/call` and verify the existing JSON-RPC response shapes are unchanged.
- [x] 1.4 Resolve the `AgentDbWeb.Context.role/1` dependency: move the pure helper into `AgentDb` (or a core utility) if feasible, otherwise keep the reference documented, and verify `mix compile` and `mix credo --strict` pass.

## 2. Compatibility shim and HTTP edge

- [x] 2.1 Replace the body of `lib/agent_db_web/mcp.ex` with `defdelegate` shims for `tools/0`, `call_tool/3`, and `handle_request/2` to `AgentDb.Mcp`, and verify `mix compile` succeeds.
- [x] 2.2 Update `lib/agent_db_web/controllers/mcp_controller.ex` to alias `AgentDb.Mcp` and verify the controller tests pass.
- [x] 2.3 Verify the HTTP `POST /mcp` endpoint still handles initialize, tools/list, and tools/call identically via an integration test.

## 3. Tests

- [x] 3.1 Add `test/agent_db/mcp_test.exs` covering `tools/0` (full inventory), `call_tool/3` success and `:model_loading`/unknown-tool/missing-argument errors, and `handle_request/2` JSON-RPC shapes, and verify `mix test test/agent_db/mcp_test.exs` passes.
- [x] 3.2 Retarget `test/agent_db_web/mcp_test.exs` to exercise the compatibility shim, and verify it passes.
- [x] 3.3 Add a sidecar smoke test that starts the app with `http_enabled: false` and invokes a tool in-process, and verify it passes.

## 4. Documentation

- [x] 4.1 Update `guides/API-REFERENCE.md` with an `AgentDb.Mcp` section (tools/0, call_tool/3, handle_request/2) and a sidecar invocation example, and verify the documented snippet compiles.
- [x] 4.2 Update `guides/ARCHITECTURE.md` to note the tool inventory is a core module reached by both the HTTP edge and in-process callers, and verify the guide renders in `mix docs`.
- [x] 4.3 Add a sidecar quickstart to `guides/SETUP.md` or `guides/USAGE.md` (dep, config with `http_enabled: false`, start, invoke) and verify the steps are consistent with the code.

## 5. Integration verification

- [x] 5.1 Run `mix test`, `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`, and verify all pass.
- [x] 5.2 Run `mix docs` and verify no warnings and the new module appears in the generated reference.

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.