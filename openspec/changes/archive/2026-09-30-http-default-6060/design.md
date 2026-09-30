# Design

## Context

See proposal.md - Why. Current state: `config/runtime.exs:16` resolves `AGENT_DB_HTTP_PORT || "4000"` once and uses it for both `http: [port:]` and `url: [port:]`. Daemon (`/api` WS + REST) and UI (`/admin`) share that one `AgentDbWeb.Endpoint` listener. Docs and examples hardcode 4000.

## Goals / Non-Goals

**Goals:**
- Change implicit default to 6060 with no behavior change when env is set.
- Keep single-source port invariant and loopback-by-default.

**Non-Goals:**
- No split of daemon vs UI onto separate ports.
- No change to auth, TLS, bind logic, or `PORT` handling (`PORT` stays ignored).
- No update to archived change docs under `openspec/changes/archive/`.

## Decisions

- Default in `config/runtime.exs` `"4000"` -> `"6060"` over adding a second setting. Rationale: preserves one-value-determines-port guarantee; alternative of new `AGENT_DB_UI_PORT` would fork the endpoint and double the surface.
- Same change in `config/example.exs` fallback and `README.md` table + `ws://localhost:6060/api` example. Rationale: docs are the contract operators copy; leaving 4000 there silently reintroduces the collision.
- Spec delta pins default `6060` in `http-api` rather than `skip_specs`. Rationale: default port is observable on fresh boot, so it is behavior, not pure refactor.

## Risks / Trade-offs

- [Risk] Operators relying on implicit 4000 break on upgrade -> Mitigation: call out BREAKING in proposal; rollback is `AGENT_DB_HTTP_PORT=4000`.
- [Risk] Hardcoded 4000 elsewhere (tests, bench, local scripts) missed -> Mitigation: grep for 4000 during implementation; tasks include verification step.
- [Risk] 6060 collides with something else locally -> Mitigation: env override still wins; no code assumes 6060 is free.

## Migration Plan

- Deploy: change default, update docs. No data migration.
- Verify: boot without env, `doctor` + TCP connect to 6060, boot with `AGENT_DB_HTTP_PORT=4000` still serves 4000.
- Rollback: set `AGENT_DB_HTTP_PORT=4000`.

## Open Questions

- None. Future `tools/` install + OpenCode/Zed snippets should default to 6060, tracked separately from this change.
