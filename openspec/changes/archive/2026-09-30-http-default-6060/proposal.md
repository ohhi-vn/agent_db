# Proposal

## Why

Local port 4000 collides with common dev servers (Phoenix, Node, Python). Moving the default to 6060 gives AgentDb a quiet default for both the WS daemon (`/api`) and the UI console (`/admin`), which share one listener.

## What Changes

- Default HTTP port `4000` -> `6060` when `AGENT_DB_HTTP_PORT` is unset.
- **BREAKING** for operators relying on the implicit default: a boot without env var now serves `127.0.0.1:6060` instead of `127.0.0.1:4000`. Explicit `AGENT_DB_HTTP_PORT` behavior is unchanged.
- Update default in `config/runtime.exs`, `config/example.exs`, and `README.md` examples/docs (`ws://localhost:6060/api`).
- No split of daemon vs UI ports: both remain the same `AgentDbWeb.Endpoint` listener by design.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `http-api`: default listener port becomes 6060; single-source port contract, loopback-by-default, and enable/disable lifecycle are unchanged.

## Impact

- Affected: `config/runtime.exs`, `config/example.exs`, `README.md`, any `tools/` install + OpenCode/Zed snippets that assume 4000 (follow-on, not in this change).
- Env override `AGENT_DB_HTTP_PORT` / `AGENT_DB_HTTP_IP` continues to win over the default; `url:` port stays derived from the same resolved value.
- Operators with hardcoded `4000` must set `AGENT_DB_HTTP_PORT=4000` or move to `6060`.
