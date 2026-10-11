# Proposal

## Why

Operators cannot verify what an LLM actually receives for a skill or document: L0 abstract, L1 overview, and L2 full content are stored per document and generated asynchronously, but the admin console shows only raw content plus two plain-text layer fields on the single-document editor, with no layer source, no size signal, and no skill-level view. This makes stale/missing/generated summaries invisible during debugging.

## What Changes

- Add an "LLM view" section to the document editor (`/admin/documents/:id/edit`) showing L0, L1, L2 side-by-side as the LLM-facing payload, each with source badge (caller-supplied / generated / fallback / missing), character count, and unavailable state.
- Add a per-skill "LLM view" reachable from the skills inventory: for a skill root URI, list each file with its L0/L1/L2 excerpt (or full layer on expand) plus the same source/size signals, so an operator sees exactly what search/recall/MCP would return for that skill.
- Read-only presentation only: reuse `AgentDb.abstract/1`, `AgentDb.overview/1`, `AgentDb.read/1` via the existing `AgentDbWeb.Context` facade; no new write path, no new routes outside `/admin/*`, no change to generation or search behavior.
- Refresh layers on live change events and periodic fallback using the existing subscribe/coalesce lifecycle; never touch an unsaved draft.

## Capabilities

### New Capabilities
- None — this change presents existing layered-content behavior in the console.

### Modified Capabilities
- `admin-dashboard`: console shows the LLM-facing L0/L1/L2 layers per document and per skill with source/size signals, read-only, inside the existing `/admin/*` pipeline and trust boundary.

## Impact

- Affected code: `DocumentEditorLive`, `Admin.SkillsLive` (or a new skill-detail LiveView under `/admin/skills/...`), `AgentDbWeb.Context` (read-only layer accessors), `AdminComponents` (new presentational components), console stylesheet.
- APIs/systems: no new network routes, no auth change, no store/index/queue change; reads go through the existing operator facade.
- Dependencies: none new.
