# Proposal

## Why

Operators cannot currently monitor or manage what the store holds: the Skills page only imports (no listing, search, or status), and the Documents page only shows the tree root's direct children with a 10-hit keyword search. There is no way to see everything, find a skill/document quickly, organize by group, or temporarily take a skill/document out of use without deleting it.

## What Changes

- Admin Documents page: add recursive paged "show all" listing (50/page, keeps existing clamping for invalid pages), full-text search over the listing with scope filter, and grouping by top-level subtree plus optional custom group tag.
- Admin Skills page: add installed-skill inventory (list all skills across users), skill search by name/path, "show all" paged listing, and grouping by owner (`user_id`) plus optional custom group tag.
- Enable/disable for skills and documents, single-item and group bulk actions:
  - Disabled = blocked from use: excluded from keyword/vector/hybrid search, recall/tool use, and default listings, but still stored, readable, and editable; re-enable restores use.
  - Toggle one skill/document, all in a group, or filtered search results as one action with per-item outcome reporting.
- Monitoring: each listing row shows status (enabled/disabled), group, URI, file count/size or updated version; bulk actions report counts (e.g. "3 disabled, 1 failed") via the shared error taxonomy, never raw terms.
- Store support: persist enabled state + group tag as metadata alongside content (not in content), keep it consistent across replace/remove/cache/index paths, and exclude disabled URIs from search/recall by default.

## Capabilities

### New Capabilities

None — this change extends existing behaviors rather than introducing a new durable domain.

### Modified Capabilities

- `admin-dashboard`: console monitoring/management — searchable, paged show-all listings, grouping, enable/disable single + bulk actions with classified feedback.
- `agent-skills`: skill inventory, search, grouping, and enable/disable (blocked-from-use) semantics including replace/remove consistency.
- `context-store`: document enable/disable (excluded from search by default), group-tag metadata, and recursive paged listing support for the console.

## Impact

- Affected code: `AgentDbWeb.Admin.{DocumentsLive,SkillsLive}`, `AdminComponents` (new listing/group/toggle components), `AgentDbWeb.Context` facade (list/search/toggle/group helpers), `AgentDb` facade + `Application.Skills` + storage layer (enabled/group metadata, search filtering, replace/remove consistency), SQLite schema/migration for new columns.
- APIs: no new network routes or auth bypass; console stays under `/admin/*` via the browser pipeline; store changes go through the existing facade.
- Compatibility: disabled defaults to enabled (existing content unaffected); search excluding disabled by default is a behavior change callers must opt out of explicitly.
