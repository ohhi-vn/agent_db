# Proposal

## Why

New users face a 633-line `README.md` mixing install, quickstart, config, and ops, plus agent setup buried in `docs/agents.md` — there is no single short path from zero to first write/read/search, and no layered setup/use reference to stay in sync with the facade, CLI, and MCP surface.

## What Changes

- Add `docs/QUICKSTART.md`: 5-minute path — prereqs, `mix deps.get`, start daemon (`iex -S mix`), first `write`/`read`/`search`, `mix agent_db.doctor` check, where to go next.
- Add `docs/SETUP.md`: full setup — Elixir 1.20+ / EXLA / SQLite, `data_dir` / `model_cache_dir`, all `AGENT_DB_*` env vars, HTTP listener (`AGENT_DB_HTTP_PORT`/`IP`/`ENABLED`), auth opt-in, Apple Silicon EMLX vs EXLA, model pre-placement and cache recovery, WSL2 notes, `tools/install.sh --check` verification and failure recovery.
- Add `docs/USAGE.md`: full use — documents (L2/L0/L1), `find`/`grep`, keyword/vector/hybrid search, memory (`remember`/`recall`/`forget`), sessions + commit, skills import, `export_data`/`import_data`, `mix agent_db.*` CLI (`--json`), MCP tools for OpenCode/Zed, WebSocket `v1.*` events, `/admin` console, trust boundary.
- Trim `README.md` to index + short pointer: keep Features/Quick Start snippet, link to the three guides, remove duplicated setup/config blocks or reduce to links.
- Verify every snippet against `AgentDb` facade, `lib/mix/tasks/*.ex`, and `docs/agents.md` so guides never disagree with code.

## Capabilities

### New Capabilities

- `usage-guides`: layered user documentation — a short quickstart plus full setup and use guides — with structure, freshness, and verification rules.

### Modified Capabilities

- None — no runtime behavior changes; existing `agent-tooling` docs requirement stays as-is.

## Impact

- Docs only: new `docs/QUICKSTART.md`, `docs/SETUP.md`, `docs/USAGE.md`; edits to `README.md` links.
- No code, API, dependency, migration, or config changes; no breaking changes.
- Risk is doc drift — mitigated by snippet verification against facade/CLI tasks in review.
