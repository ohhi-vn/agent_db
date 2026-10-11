# Design

## Context

See proposal.md Why. Update path traced read-only plus reproduction (task 1.1/1.2, recorded in proposal Impact): `AgentDb.import_skills/2` → `Skills.import/2` → per-skill `SQLite.replace_skill/2` transaction → `Cache.invalidate_removal/1` → `notify(..., :replaced)`. Store-level update is HEALTHY on all three source shapes (`{:uploads}`, `{:archive}`, `{:path}`): `:replaced` status, omitted files unreadable, warm/cold reads and listings agree, queue holds new-file jobs only, `context_changed` delivered; full suite 630 passed. The defect is console refresh only: (1) `DocumentEditorLive` never subscribes, so an open skill file stays stale forever after re-import; (2) `Admin.connect` inits `last_reload_ms: 0`, and with negative monotonic time (normal: the epoch is arbitrary) the first event's `now - 0 < coalesce` wrongly defers instead of reloading immediately. Constraints: never clobber an unsaved editor draft; per-skill atomicity and validation-before-write stay; no public API shape change.

## Goals / Non-Goals

**Goals:**
- Editor open on a skill file reflects a same-name re-import without manual reload and without losing an unsaved draft.
- Admin pages reload immediately on the first change event after mount (bursts still coalesce).

**Non-Goals:**
- No new source kinds, file types, subscription kinds, console layout, or API shape changes; no tuning of import limits; no change to the healthy replace transaction.

## Decisions

- **Editor subscribes to the tree root on connect and refreshes guarded by draft state.** Rationale: skill re-import broadcasts the skill ROOT uri (per "one event per affected URI root"), so subscribing to the open file uri alone would miss it; root subscription plus a relevance filter (event uri equals the open uri or is an ancestor of it) catches direct writes, skill replacements, and subtree removals. When saved (no unsaved changes): re-read content, draft, and layers. When dirty: never touch content/draft; refresh display-only layers and show a "changed underneath" notice naming the uri. When the doc is gone: keep the draft intact and show a "no longer stored" notice. Alternatives rejected: always-auto-reload (loses the operator's draft — data loss); notice-only without refresh (leaves stale content on screen, still needs manual reload); subscribing to the file uri only (misses skill-root broadcasts by PubSub direction).
- **Fix at the owning layers; keep the healthy replace path untouched.** Editor refresh lives in `DocumentEditorLive` (the only console page outside `use Admin`); first-event timing lives in `Admin.connect`. Rationale: matches current ownership; no duplicate guards in import surfaces. Alternative (reworking import notify granularity to per-file) rejected: violates the "one event per URI root" contract and adds noise.
- **Init `last_reload_ms` to `now - coalesce - 1` at connect.** Rationale: preserves relative burst math while making the first event reload immediately on any monotonic clock (negative, zero, or positive epoch). Alternative (special-casing `0`) rejected: magic value spreads through the cond; time-relative init keeps one comparison.
- **Preserve current `notify(..., :replaced)` kinds.** Rationale: verified delivered with correct kind; changing kinds would churn specs and feed expectations without evidence.

## Risks / Trade-offs

- [Risk] Refreshing the editor while dirty could still surprise → Mitigation: dirty refresh touches display-only layers and sets a notice; content/draft are only rewritten when saved.
- [Risk] Removed-doc notice leaves a draft with nowhere to publish (publish recreates the doc) → Mitigation: accepted and documented in the notice; publish remains last-writer-wins, matching concurrent-edit behavior.
- [Risk] Over-fixing (changing notify kinds or the replace transaction) → Mitigation: no kind/transaction change; reproduction proved that path healthy.

## Migration Plan

None. Bug fix with no schema, config, or API migration. Rollback is revert. No data repair step: successful replaces are already correct state; failed replaces leave prior state intact by existing atomicity.
