# Proposal

## Why

Setting up a useful AgentDb store for manual dev exploration, console/WebSocket demos, and test authoring is slow and inconsistent: each developer hand-writes documents, memories, and sessions, or copies fragments from tests. A single deterministic generator gives every dev and test environment the same realistic baseline in one command.

## What Changes

- New `AgentDb.Seed` Elixir API that builds a deterministic demo dataset: documents under `viking://resources/demo/`, typed memories under `viking://user/memories/`, one committed session, one skill sample, and Elixir code-index entries for the demo project.
- New `mix agent_db.seed` CLI task wrapping the API with `--json` machine-readable output (consistent with existing `agent_db.*` tasks), `--scope/prefix` override, and `--force` / `--clean` controls.
- Safety guards: refuses on a non-empty store unless `--force` (merge) or `--clean` (reset-then-seed) is given; refuses in `prod` (`Mix.env() == :prod`) unless `--allow-prod` is passed; never deletes data outside the seed scope.
- Test/Dev ergonomics: seed is callable from `test/support` and dev scripts without starting the web endpoint; works with inference unavailable (jobs enqueue, keyword paths usable immediately).

## Capabilities

### New Capabilities

- `dev-test-data`: deterministic demo-dataset generation for dev and test environments via Elixir API and Mix task, with idempotent merge, scoped reset, and unsafe-environment guards.

### Modified Capabilities

- None. Existing `context-store`, `memory`, `agent-tooling`, and `developer-environment` requirements are reused, not changed.

## Impact

- New code: `AgentDb.Seed` module (`lib/agent_db/seed.ex` or under `application/`), `Mix.Tasks.AgentDb.Seed` (`lib/mix/tasks/agent_db.seed.ex`).
- Reuses: `AgentDb.write/3`, `remember/3`, session APIs, `CodeIndex`, `JobQueue`; no new Hex dependencies.
- Docs: `docs/USAGE.md` / `docs/SETUP.md` seed section; `mix help agent_db.seed`.
- Tests use the same API for fixtures; no change to prod runtime paths, storage schema, or wire protocols.
