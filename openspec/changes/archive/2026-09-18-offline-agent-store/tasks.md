## 1. Project Scaffold

- [ ] 1.1 Create Mix project `agent_db` (`mix new . --app agent_db` layout: `mix.exs`, `lib/agent_db/application.ex`, `.formatter.exs`, `.gitignore`) and verify `mix compile` succeeds
- [ ] 1.2 Add `{:exqlite, "~> 0.40"}` to `mix.exs` deps and verify `mix deps.get && mix compile` fetches and builds the NIF

## 2. SQLite Storage Layer

- [ ] 2.1 Implement `AgentDb.Store.SQLite` helpers (open/close, WAL + foreign_keys pragmas, schema DDL for nodes, sessions, session_messages, commit metadata) and verify DDL runs idempotently on a temp-file DB in an ExUnit test
- [ ] 2.2 Implement single-writer `AgentDb.Store.Writer` GenServer (owns write connection, serializes writes) and reader connections; verify concurrent reads do not block each other and writes serialize in an ExUnit test

## 3. Cache Layer

- [x] 3.1 Implement `AgentDb.Cache.Owner` GenServer creating `node_cache` and `dir_cache` ETS tables with `heir`, plus read-through get/put/invalidate helpers; verify a killed owner is restarted by the supervisor and tables are recreated empty in an ExUnit test
- [x] 3.2 Implement invalidation-on-write helper covering node entry, parent dir entry, and ancestor dir entries; verify post-write cache state equals cold-cache-from-disk state in an ExUnit test

## 4. Public API: Tree Operations

- [x] 4.1 Implement `AgentDb.write/3` (content + optional abstract/overview) with URI validation (reject empty segments, `.`/`..`, control chars); verify persist-then-cache ordering and URI validation errors in ExUnit tests
- [x] 4.2 Implement `AgentDb.read/1`, `abstract/1`, `overview/1` with ETS-first read-through and deterministic L0/L1 fallbacks (first non-empty line / first N chars); verify verbatim and fallback scenarios from the spec in ExUnit tests
- [x] 4.3 Implement `AgentDb.list/1` and `AgentDb.tree/2` (depth-limited) backed by `dir_cache` with SQLite fallback; verify listing reflects writes and missing URIs return `{:error, :not_found}` in ExUnit tests
- [x] 4.4 Implement `AgentDb.rm/1` (recursive subtree delete) with full invalidation; verify children are gone from SQLite and cache afterwards in an ExUnit test

## 5. Public API: Search and Sessions

- [x] 5.1 Implement `AgentDb.search/2` (case-insensitive substring over content + summaries, optional subtree prefix scope, escaped LIKE, FTS5 fast path only when available); verify scoped and case-insensitivity scenarios from the spec in ExUnit tests
- [x] 5.2 Implement `AgentDb.Session` append/log API persisted in SQLite; verify append order and restart durability in ExUnit tests
- [x] 5.3 Implement `AgentDb.commit_session/3` with SHA-256 content-hash idempotency per (session, destination); verify single-document commit and no-duplicate re-commit scenario from the spec in ExUnit tests

## 6. System Verification

- [x] 6.1 ExUnit restart-recovery test: write docs + session, restart the whole supervision tree, re-read and re-search verifying identical results
- [x] 6.2 Run `mix test` (all green), `mix format --check-formatted`, and `mix credo` (if configured); fix any failures before completion
