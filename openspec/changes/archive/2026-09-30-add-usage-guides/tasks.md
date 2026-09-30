# Tasks

## 1. Short quickstart

- [x] 1.1 Write `docs/QUICKSTART.md` (prereqs, deps, start, first write/read/search, doctor check, next-step links) and verify a fresh reader reaches first search plus health check in under five minutes
- [x] 1.2 Run every `docs/QUICKSTART.md` snippet in order and verify each succeeds as written or its inline recovery fixes it

## 2. Full setup reference

- [x] 2.1 Write `docs/SETUP.md` (prereqs, data/model dirs, all `AGENT_DB_*` vars with defaults, listener, auth, EMLX/EXLA, model cache recovery, WSL2, install.sh and doctor verification with failure recovery) and verify env table matches `config/runtime.exs`
- [x] 2.2 Run every `docs/SETUP.md` command including `tools/install.sh --check` and doctor task and verify outputs match documented expectations

## 3. Full usage reference

- [x] 3.1 Write `docs/USAGE.md` documents/search/find/grep/memory/sessions/skills/export-import sections and verify each workflow shows runnable commands with expected shapes
- [x] 3.2 Write `docs/USAGE.md` CLI/MCP/WebSocket/admin/trust-boundary sections and verify tool names, event names, options, and editor snippets agree with `docs/agents.md` and `mix agent_db.* --help`
- [x] 3.3 Run every `docs/USAGE.md` snippet and verify each succeeds as written or its documented error meaning resolves it

## 4. Index and final check

- [x] 4.1 Retrim `README.md` to Features plus short pointer with links to the three guides and verify links land within the first two screens with no conflicting duplicates
- [x] 4.2 Run `openspec validate --change add-usage-guides --strict` and verify it passes, fixing any spec or artifact errors
