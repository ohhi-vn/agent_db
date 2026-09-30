# Agent setup: OpenCode and Zed

AgentDb runs one shared daemon both editors talk to over MCP Streamable HTTP:

- Default URL: `http://127.0.0.1:6060/mcp` (port from `AGENT_DB_HTTP_PORT`, default `6060`)
- Default auth: none on loopback. Opt-in Bearer via `AGENT_DB_HTTP_AUTH=true` plus tokens in `AGENT_DB_HTTP_AUTH_TOKENS`.
- CLI fallback: `mix agent_db.*` tasks with `--json` for machine-readable output.

## 1. Start the daemon

```bash
iex -S mix
```

With auth:

```bash
AGENT_DB_HTTP_AUTH=true AGENT_DB_HTTP_AUTH_TOKENS=<token> iex -S mix
```

Check it:

```bash
tools/install.sh --check
mix agent_db.doctor
```

## 2. OpenCode

Paste into `opencode.jsonc` (default, no auth):

```jsonc
{
  "mcp": {
    "servers": {
      "agent-db": {
        "type": "remote",
        "url": "http://127.0.0.1:6060/mcp"
      }
    }
  }
}
```

Bearer opt-in variant:

```jsonc
{
  "mcp": {
    "servers": {
      "agent-db": {
        "type": "remote",
        "url": "http://127.0.0.1:6060/mcp",
        "oauth": false,
        "headers": {
          "Authorization": "Bearer <token>"
        }
      }
    }
  }
}
```

## 3. Zed

Paste into `settings.json` under `context_servers` (default, no auth):

```json
{
  "context_servers": {
    "agent-db": {
      "url": "http://127.0.0.1:6060/mcp"
    }
  }
}
```

Bearer opt-in variant:

```json
{
  "context_servers": {
    "agent-db": {
      "url": "http://127.0.0.1:6060/mcp",
      "headers": {
        "Authorization": "Bearer <token>"
      }
    }
  }
}
```

Check the green indicator next to the server in Settings → AI → MCP Servers.

> Shapes differ: OpenCode local servers use `"command": [...]` (one array)
> while Zed uses `"command": "..."` plus a separate `"args": [...]`.
> One local snippet cannot serve both editors verbatim; the remote URL shape
> above is shared.

## 4. Windows (WSL2)

Run the daemon and installer inside WSL2; point Windows editors at
`http://localhost:6060/mcp`. From PowerShell:

```powershell
wsl bash tools/install.sh --check
```

`tools/install.ps1` refuses native execution on purpose: native Windows has
no supported EXLA path, so a native install would look done while inference
cannot work.

## 5. CLI fallback

```bash
mix agent_db.read "viking://resources/myapp/readme.md" --json
mix agent_db.search "authentication" --mode hybrid --json
mix agent_db.find "auth" --scope viking://resources/myapp --json
mix agent_db.grep "def run" --scope viking://resources/myapp --json
mix agent_db.recall --type preferences --json
mix agent_db.tree viking://resources/myapp --depth 2 --json
mix agent_db.doctor --json
```

Without `--json` the same tasks print human-readable text. Failures exit
non-zero.

## 6. Tools

| MCP tool | Facade |
|----------|--------|
| `context_read`, `context_write`, `context_rm` | `read`, `write`, `rm` |
| `context_list`, `context_tree` | `list`, `tree` |
| `context_search`, `context_find`, `context_grep` | `search`, `find`, `grep` |
| `memory_recall`, `memory_remember`, `memory_forget` | `recall`, `remember`, `forget` |
| `session_create`, `session_append`, `session_get`, `session_commit` | sessions |
| `store_health` | `health_check` + `model_status` + `queue_stats` |

Errors are JSON (`{"code": ..., "message": "..."}`). A `model_loading`
message means retry later; anything else names the cause. The session stays
usable after an error.

## 7. Trust boundary

The default no-auth daemon binds loopback only: any local process can read
*and write*. That fits one laptop shared by your two editors and nothing
else. To serve beyond loopback, set `AGENT_DB_HTTP_IP`, enable Bearer auth,
and keep the port off wider networks than intended.
