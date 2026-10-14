# Guides

Task-oriented documentation for AgentDb. Start with the row that matches what
you are trying to do.

| Guide | Audience | What it covers |
|-------|----------|----------------|
| [QUICKSTART.md](QUICKSTART.md) | New users | Five minutes from prerequisites to a verified write, read, search, and health check |
| [SETUP.md](SETUP.md) | Operators | Full install: directories, every `AGENT_DB_*` variable, listener, auth, backends, WSL2 notes, verification |
| [USAGE.md](USAGE.md) | Daily users | Documents, layered summaries, `find`/`grep`, keyword/vector/hybrid search, memory, sessions, skills, CLI, MCP, WebSocket |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Developers | Component boundaries, data flows, deployment topology, and how the store, inference, queue, and transports fit together |
| [MONITORING.md](MONITORING.md) | Operators | Production observability: the `/admin` console, telemetry events, structured logs, health checks, error taxonomy, alerting |
| [API-REFERENCE.md](API-REFERENCE.md) | Integrators | All four public interfaces — Elixir API, CLI, MCP tools, WebSocket events — with request/response shapes and the unified error catalog |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Operators | Symptom-first diagnostics: each symptom with diagnostic commands, expected output, and resolutions |
| [agents.md](agents.md) | Editor users | Canonical OpenCode and Zed setup snippets, WSL2 workflow, and CLI fallback |

The Elixir module API reference is generated from the code — see
[mix docs](https://hexdocs.pm/agent_db/AgentDb.html) or run `mix docs`
locally. [API-REFERENCE.md](API-REFERENCE.md) maps every entry point to it.
