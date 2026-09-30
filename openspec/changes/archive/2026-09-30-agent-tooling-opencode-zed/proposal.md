# Proposal

## Why

Agents in OpenCode and Zed cannot use AgentDb without hand-rolled Phoenix Channel glue or brittle shell parsing. A shared remote daemon with copy-paste configs plus machine-readable CLI fallback unblocks both editors on day one.

## What Changes

- New `/mcp` Streamable HTTP endpoint on the existing `6060` listener (assumes `http-default-6060` applied), exposing full read-write facade as MCP tools (`initialize`, `tools/list`, `tools/call`, protocol `legacy`).
- Default no-auth loopback; opt-in Bearer via existing `AGENT_DB_HTTP_AUTH`/`TOKENS` surfaced as optional headers in snippets. No split daemon/UI ports.
- CLI++: add missing `read`, `find`, `grep`, `recall` tasks and `--json` flag across tasks (text stays default) for shell agents.
- Install: `install.sh` (macOS/Linux/WSL via brew/apt, models fetch) + tiny `install.ps1` (check WSL + delegate). Prints OpenCode (`mcp.servers`) + Zed (`context_servers`) snippets; verifies daemon `6060` + files exist, never auto-merges editor JSON.
- Usage guide for OpenCode + Zed (remote URL, Bearer opt-in, CLI fallback, `doctor` verification).

## Capabilities

### New Capabilities

- `agent-tooling`: MCP tool contract + CLI machine output + install verification + editor setup guide for OpenCode/Zed.

### Modified Capabilities

- `http-api`: expose `/mcp` on the configured listener with existing single-port, loopback-default, optional-auth, and trace contracts.

## Impact

- New: `lib/agent_db_web/controllers/mcp_controller.ex` (or router route), MCP tool schemas, `lib/mix/tasks/agent_db.{read,find,grep,recall}.ex` + `--json` handling, `tools/install.sh`, `tools/install.ps1`, guide docs.
- Depends on `http-default-6060` for `6060` default; `AGENT_DB_HTTP_PORT` override still wins.
- Risk: full read-write on default no-auth loopback — any local proc can write; mitigated by loopback-only default + documented Bearer opt-in.
