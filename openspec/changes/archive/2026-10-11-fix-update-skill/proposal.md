# Proposal

## Why

Re-importing an Agent Skill under an already-stored name (the update path) does not observably update in the console: operators report the console doesn't refresh. The store-level replace works (all `{:uploads}` / `{:archive}` / `{:path}` re-imports replace whole-subtree with `:replaced` status and consistent reads), so the failure is console refresh, not storage: the document editor never subscribes to store changes, and admin pages defer their first reload.

## What Changes

- Reproduce the broken update path end-to-end across both import surfaces (admin UI upload/archive and `mix agent_db.import_skills` path) before changing behavior.
- Fix the root cause so re-importing the same skill name for the same user replaces the whole stored subtree: new files land, omitted files become unreadable, other skills/users are untouched.
- Keep post-replace consistency: document tree, vector index, pending background jobs, read cache, and `context_changed` notification agree with the replacement; a failed replacement leaves the prior subtree intact.
- Report the per-skill outcome correctly (`:replaced` vs `:imported` vs `:failed` with actionable reason) on both surfaces.
- Add regression coverage for the reproduced failure (same-name re-import via the failing surface plus stale-read/queue/search consistency).
- Make the console reflect skill updates without manual reload: the document editor subscribes and refreshes its stored sections (never clobbering an unsaved draft), and admin pages reload immediately on the first change event.
- Add regression coverage for the reproduced failures (LiveView refresh after skill update; first-event immediate reload).

## Capabilities

### New Capabilities

None — this is a bug fix to existing replace behavior, not a new capability.

### Modified Capabilities

- `agent-skills`: clarify/fix the observable update contract for "Replace a same-name skill as one complete subtree" — same-name re-import via either surface must replace whole-subtree with cache/queue/index consistency and correct per-skill status. Existing scenarios (replace + remove stale files, failed replacement preserves, partial multi-skill outcomes) remain; the delta tightens what "update works" means so the reported failure is rejected by spec.

## Impact

- Affected code: `lib/agent_db_web/live/document_editor_live.ex` (subscribe + guarded refresh), `lib/agent_db_web/live/admin.ex` (first-event reload init), plus the verified-healthy replace path (`lib/agent_db/application/skills.ex`, `lib/agent_db/adapters/sqlite.ex` `replace_skill`, `lib/agent_db/agent_db.ex` `import_skills` notify, `lib/agent_db/cache.ex`, `lib/agent_db_web/live/admin/skills_live.ex`, `lib/mix/tasks/agent_db.import_skills.ex`).
- Diagnosis (recorded from reproduction, replaces the earlier assumption): store-level update works on all three source shapes with `:replaced` status, whole-subtree replacement, cache/queue/event consistency (repro + 630-test suite green). Two console defects found: (1) the document editor never subscribes, so an open skill file stays stale forever after re-import; (2) admin pages defer the first change event ~1s because `last_reload_ms: 0` sits in the future when monotonic time is negative, so `now - 0 < coalesce` wrongly coalesces.
- APIs: no public API shape change; `import_skills/2` return shapes unchanged.
- Out of scope: new import source kinds, new skill file types, changes to subscription kinds or console layout, clobbering an unsaved editor draft (the fix must preserve it).
- Out of scope: new import source kinds, new skill file types, changes to subscription kinds or console layout.
