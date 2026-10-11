# Design

## Context

See proposal.md (Why) and `specs/dev-test-data/spec.md` for requirements. Current state shaping the approach:

- All store writes go through the `AgentDb` facade (`write/3`, `remember/3`, `create_session/append/commit`, `import_skills/2`, `CodeIndex.index_source/3`), which handles validation, cache invalidation, PubSub notify, and background job enqueue. Direct storage writes would bypass those.
- CLI tasks share one shape (`Mix.Tasks.AgentDb.Doctor`, `Index`): `@requirements ["app.config"]`, `OptionParser` strict switches, `Mix.Task.run("app.start", ...)`, human text by default plus `--json` via Jason, `Mix.raise` on failure.
- Memories are typed by URI (`viking://user/memories/<type>/<name>`, types: profile, preferences, entities, events, experiences) and embed without summarization; keyword `search/2` scoped to the memories root works with no model.
- Skills import accepts `{:uploads, [%{path, content}]}` and replaces a same-named skill whole; code index writes ordinary documents under `viking://resources/<project>/code/`.

## Goals / Non-Goals

**Goals:**
- One deterministic dataset exercising every read path (read/search/find/grep/recall/session/skill/code) with zero new dependencies and no model required.
- Idempotent re-seed, scoped reset, and safe defaults for dev/test.

**Non-Goals:**
- Random/fuzz data, large-scale benchmarks (bench/ covers that), production migration, console UI page, vector-embedding bundling in the seed artifact.

## Decisions

### 1. New public `AgentDb.Seed` over the facade (not storage)
`AgentDb.Seed.seed(opts)` calls `AgentDb.write`, `remember`, session APIs, `import_skills("demo", {:uploads, [...]})`, and `CodeIndex.index_source("demo", ...)`, returning `{:ok, report}` / `{:error, reason}` where `report = %{prefix, documents, memories, session, skills, indexed}`.
- *Why:* reuses validation, cache/PubSub, job enqueue; no schema or adapter change.
- *Alternative (direct `Runtime.storage()` writes):* rejected — bypasses invalidation/notify and duplicates URI validation.

### 2. Fixed embedded fixtures, no generator library
~5 markdown docs under `<prefix>/` (readme, auth-notes, runbook, glossary, changelog), one memory per type (5 total) under `viking://user/memories/<type>/demo-*`, one 3-message session committed to `<prefix>/sessions/intro.md`, one `demo-skill` (`SKILL.md` + 1 reference file) for user `demo`, two `.ex` sources indexed as project `demo`.
- *Why:* deterministic, reviewable, no Faker dep; each fixture contains distinctive keywords (`seedling-auth`, `demo-runbook`) so tests/demos can assert search/find/grep hits.
- *Alternative (Faker/StreamData):* rejected — nondeterministic, new dep, harder assertions.

### 3. Emptiness = store-wide, reset = seed-scoped
- Non-empty check: `AgentDb.tree("viking://resources", 1)` has children OR `AgentDb.recall()` returns rows (sessions uncommitted are ignored — documented). Non-empty without `force: true` / `clean: true` returns `{:error, :store_not_empty}` with nothing written.
- `force: true` merges (write/revise in place, skill replace-whole is the existing semantic). `clean: true` removes only the seed scope first (`AgentDb.rm(prefix)`, `forget` demo memory URIs, `rm` demo skill subtree and demo code prefix), then seeds; data outside the scope is never touched.
- *Alternative (prefix-only emptiness):* rejected — would silently mix demo data into a real store.

### 4. Prod guard lives in the Mix task, mirrored as an API opt
`mix agent_db.seed` refuses when `Mix.env() == :prod` unless `--allow-prod`; `Seed.seed/1` takes `allow_prod:` (default false) and the task passes it through. The library never calls `Mix.env` itself so releases without Mix still behave via the explicit opt.
- *Switches:* `--prefix` (default `viking://resources/demo`), `--force`, `--clean`, `--allow-prod`, `--json`, `--no-compile` — same parsing/raise/JSON pattern as `agent_db.index`.

## Risks / Trade-offs

- [Background jobs pending after seed] → Mitigation: seed uses default async writes; keyword/find/grep paths work immediately; docs note vector/summary results arrive progressively and `async: false` is not forced.
- [Skill re-seed replaces whole skill] → Mitigation: intended (matches existing replace-whole semantic); demo skill is isolated to user `demo` so no other skill is touched.
- [Store-wide emptiness check cost on huge stores] → Mitigation: depth-1 tree + bounded recall; seed refuses fast on first evidence, no full scan.
- [Uncommitted sessions invisible to emptiness check] → Mitigation: documented limitation; `--clean` never deletes sessions, only the committed session document.

## Migration Plan

Additive only: new module + new Mix task + docs section. No storage migration, no config change, no wire-protocol change. Rollback is `AgentDb.rm(prefix)` plus forgetting the `demo-*` memory URIs (documented in task help); re-seed converges.

## Open Questions

None. Prefix default (`viking://resources/demo`, user `demo`) and fixture keywords are fixed by this design; anything else is a follow-up change, not a spec/approach blocker.
