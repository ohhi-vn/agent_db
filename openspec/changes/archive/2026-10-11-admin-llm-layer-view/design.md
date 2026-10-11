# Design

## Context

See proposal.md Why. Current state:
- `DocumentEditorLive` (`/admin/documents/:id/edit`) already reads L0/L1 via `AgentDb.abstract/1` + `AgentDb.overview/1` in `assign_layers/1` and renders them as two plain `<dd>` fields; L2 is the editable textarea/draft.
- `AgentDb.Application.Documents.abstract/1` returns `node.abstract || first_line(content)` and `overview/1` returns `node.overview || first_chars(content)` — stored vs fallback is collapsed at the facade; raw `get_node` is the only place nil-ness is visible.
- `Admin.SkillsLive` has inventory rows (name, owner, URI, file count, status, group) but no per-skill file/layer detail; `AgentDbWeb.Context` has `list_all_documents` (scoped, paged) and no layer accessors.
- All console pages share `AgentDbWeb.Admin` lifecycle: subscribe to `viking://` root on connect, coalesce bursts (1s), 30s periodic refresh fallback, `load/1` per page.

## Goals / Non-Goals

**Goals:**
- Read-only LLM view per document and per skill showing exactly what `abstract`/`overview`/`read` return, with source and size signals.
- Zero new write paths, auth changes, or store/index behavior changes.

**Non-Goals:**
- Distinguishing caller-supplied vs LLM-generated stored layers (store does not record provenance; would need schema + job-metadata change).
- Editing layers from the console; changing generation, search ranking, or MCP payloads.
- Full-text skill concatenation / token counting; char counts are the size signal.

## Decisions

- **Layer source = stored vs fallback vs unavailable (not 4-way).** Rationale: `Documents` collapses caller-supplied and generated into a stored non-nil column; telling them apart needs provenance the store lacks. UI shows `stored` (caller or generated), `fallback` (derived from L2 at read time), `unavailable` (read error / missing doc). Alternatives rejected: exposing job history as provenance (fragile, jobs are pruned); adding a provenance column (schema migration, out of scope for a console view).
- **One `Context.get_layers/1` facade accessor owns source detection.** Reads raw node presence (via existing `AgentDb` node read) plus `abstract`/`overview`/`read`, returns `{text, source, chars}` per layer. Rationale: keeps LiveViews presentation-only and preserves "console reaches store only through the facade" invariant. Alternative (LiveViews calling `AgentDb` directly, as the editor does today) rejected: spreads source logic across pages.
- **Document editor: extend in place, no new route.** Add an "How the LLM sees this document" card below the publish form reusing extended `assign_layers`; refresh in `refresh_stored/2` (display-only, draft guard unchanged). Rationale: editor already owns the URI lifecycle and draft guard; a second route would duplicate it.
- **Skill view: in-page expandable panel in `SkillsLive`, no router/nav change.** Each inventory row gets an LLM-view toggle that loads files via existing `Context.list_all_documents(scope: skill_uri, page, per_page: 50)` and renders per-file L0/L1/L2 excerpt via `get_layers/1`. Rationale: avoids a new `/admin/skills/*` route, nav entry, and `Admin` page contract change; bounded paging matches the existing show-all pattern. Alternative (dedicated `SkillDetailLive` route) rejected: more surface for the same read-only content.
- **Reuse existing refresh lifecycle, no new PubSub topics.** Both views reload layers in `load/1` + `handle_info({:context_changed,...})` with the current coalesce/periodic path. Rationale: matches "console reflects store changes in realtime" requirement with no new subscription semantics.

## Risks / Trade-offs

- [Risk] Skill with many files × 3 layer reads per file = N+1 reads on expand → Mitigation: reuse the 50/page bound from the show-all listing; render excerpts with on-demand full-layer expand per file; rely on existing ETS read cache.
- [Risk] `stored` badge hides caller-vs-generated distinction operators may want → Mitigation: label it honestly ("stored") and record the provenance split as a future store change, not a console guess.
- [Risk] Layer text may contain large blobs → Mitigation: excerpt with `<details>`/expand, escape as text (existing HEEx escaping), never render as HTML.

## Migration Plan

Console-only, backward compatible: no migrations, no config, no API change. Rollback = revert the LiveView/component/template change; store data untouched.

## Open Questions

None — source granularity and route choice are decided above and do not change specs or tasks.
