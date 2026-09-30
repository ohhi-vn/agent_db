# Tasks

## 1. MCP endpoint

- [x] 1.1 Add `POST /mcp` route with `legacy` `initialize`, `tools/list`, `tools/call` handling and verify handshake plus tool inventory return as JSON
- [x] 1.2 Map all `context_*`, `memory_*`, `session_*`, `store_health` tools to the facade with shared option names and verify each tool calls its facade operation with validation preserved
- [x] 1.3 Render MCP errors as JSON strings or maps with `model_loading` distinct and verify unservable and loading calls return errors without ending the session
- [x] 1.4 Enforce existing optional Bearer auth and W3C trace propagation on `/mcp` and verify unauthorized without token when enabled plus trace header preserved

## 2. CLI machine output

- [x] 2.1 Add `mix agent_db.read`, `mix agent_db.find`, `mix agent_db.grep`, `mix agent_db.recall` tasks and verify each lists in `mix help` and reaches its facade operation
- [x] 2.2 Add `--json` flag across CLI tasks with human text as default and verify `--json` prints parseable JSON while bare invocations keep current lines

## 3. Install and guide

- [x] 3.1 Add `tools/install.sh` using brew/apt for prereqs with snippet printing plus daemon and file verification and verify `--check` fails helpfully when Elixir or daemon is missing
- [x] 3.2 Add `tools/install.ps1` that checks for WSL and delegates to `install.sh` and verify it refuses native Windows execution with guidance
- [x] 3.3 Add `docs/agents.md` with OpenCode and Zed remote snippets for `6060`, Bearer opt-in, WSL notes, and CLI fallback plus README pointer and verify both pasted snippets reach `tools/list`
