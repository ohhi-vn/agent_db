# Tasks

## 1. Seed API (`AgentDb.Seed`)

- [x] 1.1 Implement `AgentDb.Seed.seed/1` core dataset (docs, memories, session commit) with deterministic fixtures and per-kind report, and verify `mix test test/agent_db/seed_test.exs` covers first-run readability via read/recall/session-get plus keyword/find/grep reachability without models
- [x] 1.2 Implement idempotent merge, `force`/`clean` scoped reset, store-wide emptiness check, and `allow_prod` guard in `Seed`, and verify `mix test test/agent_db/seed_test.exs` covers re-seed convergence, non-empty refusal with nothing written, force-merge vs clean-scope-only behavior, custom prefix isolation, and prod refusal
- [x] 1.3 Add demo skill import (`demo` user, `{:uploads, ...}`) and demo code-index entries (`CodeIndex.index_source("demo", ...)`) to the seed plus report counts, and verify `mix test test/agent_db/seed_test.exs` covers skill read-back, replace-whole re-seed, and code discoverability

## 2. CLI (`mix agent_db.seed`)

- [x] 2.1 Implement `Mix.Tasks.AgentDb.Seed` with `--prefix/--force/--clean/--allow-prod/--json/--no-compile` following the `agent_db.index` shape (app.config + app.start, human text default, JSON stdout, `Mix.raise` on failure), and verify `mix test test/mix/tasks/seed_test.exs` covers JSON output, human output unchanged, and non-zero exit with reason on stderr
- [x] 2.2 Document the task help (`mix help agent_db.seed` semantics: guards, scoped reset, rollback via `rm` + `forget`) and verify the documented commands run as written (`mix help agent_db.seed`, `mix agent_db.seed --help` if supported)

## 3. Guides and gate verification

- [x] 3.1 Document seeding in `docs/USAGE.md` (or `docs/SETUP.md` dev section): when to use, default prefix, `--force` vs `--clean`, prod guard, and inference-unavailable note, and verify each documented command runs as written
- [x] 3.2 Run full verification and verify green: `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix test`, `mix lint:quick`, and `openspec validate --change add-dev-test-data-generator --strict`
