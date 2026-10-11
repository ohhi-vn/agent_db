# Design

## Context

See proposal.md (Why) and specs (WHAT). Current state shaping the approach:

- Console pages (`AgentDbWeb.Admin.{DocumentsLive,SkillsLive}` + `AdminComponents`) reach the store only through `AgentDbWeb.Context`, which shapes `AgentDb` facade results. Shared LiveView lifecycle (`AgentDbWeb.Admin`: subscribe to `viking://`, coalesce 1s, 30s refresh fallback) must keep working.
- Store: SQLite `nodes(uri PK, parent_uri, kind, content, ...)` is source of truth; ETS is disposable cache; `add_missing_columns` is the established widening-migration pattern. Search paths: `Store.Nodes.search/find_paths/grep_content`, vector index `vec_nodes` (sqlite-vec, optional), memory recall via `memory_meta`.
- Skills: `Application.Skills.import/replace` + `Skills.Source` validation; replace is per-skill atomic with `Cache.invalidate_removal`. No inventory, status, or grouping exists today.

## Goals / Non-Goals

**Goals:**
- One metadata ownership point for enabled/group that search, listing, recall, replace, remove, and cache all honor.
- Console show-all/search/group/toggle reuses existing pagination, realtime, feedback, and trust-boundary patterns.
- Zero-downtime migration: pre-change rows read as enabled/ungrouped.

**Non-Goals:**
- New routes, auth, or transports; full-text ranking changes; per-file ACLs/roles; version history; session indexing (still out of scope per admin-dashboard spec).

## Decisions

### 1. Denormalized per-node `enabled` + `group_tag` on `nodes`, bulk-applied to subtrees
- **What:** widen `nodes` with `enabled INTEGER NOT NULL DEFAULT 1`, `group_tag TEXT NOT NULL DEFAULT ''` via `@added_columns` + fresh-DB DDL. Subtree toggle = one bulk `UPDATE ... WHERE uri = ? OR uri LIKE ? || '/%'`. New writes inherit the parent's effective state (disabled parent → new child disabled; custom tag inherited only when set at the toggled root, else explicit).
- **Why over ancestor-walk-at-query:** search/listing `WHERE enabled = 1` stays a cheap indexed predicate; ancestor walk per candidate would cost per-row joins on hot paths and complicate vector post-filtering.
- **Why over separate meta table:** one row, one write, no join for every listing/search; matches `nodes` as the single URI-keyed source of truth. Index: `idx_nodes_enabled (enabled)`, `idx_nodes_group (group_tag)`.
- **Alternative rejected:** separate `node_meta` table — extra join on every search/listing for no lifecycle benefit.

### 2. Vector search honors disabled via over-fetch + store-side filter
- **What:** `search_vector` over-fetches (e.g. `top_k * 3`, capped at max 200) then inner-joins candidate URIs against `nodes.enabled = 1` (plus group/status filters), truncating to `top_k`. Hybrid (RRF) fuses already-filtered keyword + vector sets. `disabled-included` opt-in skips the predicate.
- **Why:** sqlite-vec virtual table cannot carry the predicate itself; post-filter in storage (not after materializing blobs) keeps the bound honest. Over-fetch bounds the recall loss when disabled rows interleave.
- **Alternative rejected:** deleting vectors on disable — would force re-embedding on re-enable and break "restore without re-import".

### 3. Skill inventory derived from `nodes`, not a new table
- **What:** `Context.list_skills(prefix viking://user/, page, search, owner, group, status)` = recursive `nodes` query for `kind='dir'` at depth `user/{id}/skills/{name}` + per-root aggregate (file count via descendant count, status = root's `enabled`, group = owner + custom tag). Replace preserves root's `enabled`/`group_tag` (copy before subtree replace, restore after).
- **Why:** skills are already subtrees; a second registry would drift from the tree. Aggregation is bounded (paged roots, counts via `COUNT(*)` not blob loads).

### 4. Console extends existing LiveViews/components, same facade
- **What:** `DocumentsLive` gains `mode: tree | all`, `filter`, `group`, `status` assigns + `toggle`/`bulk_toggle`/`set_group` events; `SkillsLive` gains inventory assigns alongside the import form. New `AdminComponents` table rows (status pill, group label, toggle buttons, group filter select). All actions go through new `Context` functions (`list_all_documents`, `list_skills`, `set_enabled`, `set_group`, bulk variants) which delegate to `AgentDb`; errors render via `Observability.error_message`, never `inspect`.
- **Why over new pages/routes:** preserves `/admin/*` trust boundary, sidebar, realtime lifecycle (`load/1` reloads listings; working state like search text survives reload per `Admin.reload`).
- **Pagination:** reuse `page_of` clamping (nearest valid page) for show-all at 50/page.

### 5. Group validation as classified errors
- **What:** custom tag: 1–64 chars, `[A-Za-z0-9_/-]` plus space? Chosen: letters/digits/dash/underscore/slash, max 64, empty clears. Failures return `{:error, {:invalid_group, tag}}` surfaced via shared taxonomy.
- **Why:** prevents URI/path injection and keeps tags display-safe without new sanitization paths.

## Risks / Trade-offs

- [Risk] Bulk subtree update on huge trees holds a write lock → Mitigation: single `UPDATE ... WHERE` in one transaction (no row-by-row), same pattern as removal; console reports counts, operator retries on busy via existing contended-write retry.
- [Risk] Vector over-fetch still misses when disabled density is high → Mitigation: cap documented (3x, max 200); disabled-included opt-in and keyword path remain exact; acceptable for an operations toggle, not a security boundary.
- [Risk] Denormalized status can drift if a future writer bypasses the facade → Mitigation: all writes funnel through `Writer` + `Runtime.storage()`; new columns default safe (enabled), tests assert write/replace/remove preserve them.
- [Risk] Show-all on giant stores is heavy → Mitigation: stays paged (50, max 200), counts via `COUNT(*)`, no blob materialization; no unbounded "export all" in scope.
- [Trade-off] Disabled is blocked-from-use, not access control: direct reads still serve content (per spec) — operators must remove, not disable, to hide content from readers with direct access.

## Migration Plan

1. Deploy: `add_missing_columns` adds `nodes.enabled`, `nodes.group_tag` + indexes on boot; old DBs widen in place, fresh DBs include columns in `base_ddl`. All existing rows read enabled/ungrouped — no backfill job.
2. Ship store filtering first (disabled excluded by default, opt-in flag), then facade, then console (toggles hidden until facade lands — single release, no flag needed).
3. Rollback: code rollback is safe; extra columns ignored by old code (nullable-safe defaults). No data rewrite to undo.
4. Verify: `mix test test/agent_db_web/live/admin_console_test.exs` + new inventory/toggle tests; manual: disable a skill/doc → search excludes, read still works, re-enable restores.

## Open Questions

None — enable semantics (blocked-from-use), grouping (owner/subtree + custom tag), and show-all bounds (paged 50) were confirmed with the requester before planning.
