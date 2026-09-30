# Design

## Context

See proposal.md - Why. Current state: facade covers all ops; WS `v1.*` covers ~20 events; CLI has 5 tasks with human text; no `/mcp` route, no MCP dep, no `tools/` or editor snippets. `http-default-6060` (planned) moves the single listener default to `6060`. This change adds the remote agent surface on top of it.

## Goals / Non-Goals

**Goals:**
- One remote URL both editors share: `http://127.0.0.1:6060/mcp`.
- Full facade parity over MCP with JSON errors and `model_loading` distinct.
- CLI parity for shell agents via `--json` without breaking human output.
- Install that delegates prereqs, prints snippets, verifies, never merges JSON.

**Non-Goals:**
- No native Windows daemon (WSL2 path only); no auto-edit of editor configs.
- No `protocol: auto` 2026-07-28 support day one (`legacy` only); no per-tool auth scopes beyond existing Bearer on/off.
- No split daemon/UI ports; no change to store semantics.

## Decisions

- `POST /mcp` Plug controller reusing `AgentDb` facade (not WS loopback call). Rationale: in-process avoids extra hop + auth confusion; alternative of proxying to Channel duplicates error mapping and inherits the known tuple-encode 500 shape.
- Hand-rolled minimal `legacy` JSON-RPC (`initialize`, `tools/list`, `tools/call`) with `Jason`, no new hex MCP dep. Rationale: surface is ~16 tools with fixed schemas; a dep adds supply-chain + version tracking for little gain. Revisit when `auto` is needed.
- Tool names prefixed (`context_*`, `memory_*`, `session_*`, `store_health`) mapping 1:1 to facade opts (`mode`, `scope`, `top_k`, `limit`). Rationale: avoids collisions in shared agent tool namespace; keeps CLI/MCP/WS option names identical.
- CLI `--json` prints `Jason.encode!` result to stdout, failures via `Mix.raise`. Rationale: matches existing task error contract (non-zero + message); alternative of custom exit codes adds per-task branches.
- `tools/install.sh` (bash, brew/apt, `doctor` + `curl /mcp` verify) + `tools/install.ps1` (WSL check + delegate). Rationale: two scripts share Linux logic; native Windows EXLA risk avoided.
- Guide at `docs/agents.md` + README pointer. Rationale: snippets + Bearer + WSL notes exceed README space; alternative README-only would bloat the front page.

## Risks / Trade-offs

- [Risk] Full write on default no-auth loopback lets any local proc mutate store -> Mitigation: loopback-only default, Bearer opt-in documented, destructive tools named explicitly in guide.
- [Risk] OpenCode `command` array vs Zed `command` string confusion -> Mitigation: separate snippets per editor, guide calls out non-interchangeability, install never writes them.
- [Risk] `legacy` vs `auto` protocol probe adds extra process/timeout in OpenCode -> Mitigation: document `protocol: legacy` (default) suffices; `auto` deferred.
- [Risk] WSL2 localhost forwarding surprises on Windows -> Mitigation: guide covers `localhost:6060` from Win editors to WSL daemon + `AGENT_DB_HTTP_IP` bind note.
- [Risk] Depends on `http-default-6060` landing first; without it default is `4000` -> Mitigation: snippets read `AGENT_DB_HTTP_PORT` with `6060` assumed; tasks verify against configured port, not hardcoded.

## Migration Plan

- Land `http-default-6060`, then this change. No data migration.
- Verify: `tools/install.sh --check`, `curl POST /mcp tools/list` from both snippet shapes, `mix agent_db.read --json`, `doctor` on 6060, Bearer-off default + Bearer-on variant.
- Rollback: remove `/mcp` route + tools; CLI `--json` additive so old invocations unaffected; install scripts deletable.

## Open Questions

- None blocking. Exact per-tool JSON schemas (e.g. `top_k` defaults, `limit` bounds) follow facade validation and are pinned during implementation.
