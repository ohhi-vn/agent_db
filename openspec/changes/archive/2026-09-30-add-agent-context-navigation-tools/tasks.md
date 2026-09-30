# Tasks

## 1. Storage Provider Support

- [x] 1.1 Add path-discovery and line-match result types and callbacks to `AgentDb.Core.Storage`, then implement them in the SQLite adapter and test provider; verify the storage provider contract test passes.
- [x] 1.2 Extend storage contract tests for scoped path matching, exact subtree boundaries, literal wildcard characters, deterministic ordering, line numbers, excerpt bounds, and result limits; verify `mix test test/agent_db/adapters/sqlite_contract_test.exs` passes.

## 2. In-Process Navigation API

- [x] 2.1 Implement `Documents.find/2` and `Search.grep/2`, validate query/scope/limit inputs, and expose both through `AgentDb`; verify focused API tests pass.
- [x] 2.2 Add facade tests for empty/oversized queries, malformed or missing scopes, invalid limits, L2-only grep, bounded results, and unchanged search behavior; verify `mix test test/agent_db/navigation_test.exs test/agent_db_test.exs` passes.

## 3. Remote Agent API and Documentation

- [x] 3.1 Add `v1.find` and `v1.grep` channel handlers with a strict `scope`/`limit` option whitelist; verify channel tests assert result shapes, error responses, and continued use of the same socket after invalid input.
- [x] 3.2 Document in-process and WebSocket usage, matching semantics, defaults, hard limits, and the required storage callbacks; verify README and `Core.Storage` documentation describe the same contracts as the specs.

## 4. Integration Verification

- [x] 4.1 Run `mix format --check-formatted` and the full `mix test` suite; resolve any regressions in existing tree navigation, search, memory, or channel behavior.
- [x] 4.2 Run `openspec validate --change "add-agent-context-navigation-tools"` and confirm the proposal, both capability deltas, design, and tasks validate together.
