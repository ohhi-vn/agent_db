# Design

## Context

See `proposal.md` Why. Current state: `README.md` (633 lines) is the de facto manual plus `docs/agents.md` for OpenCode/Zed; sources of truth are `AgentDb` facade, `lib/mix/tasks/*.ex`, `config/runtime.exs`, and `tools/install.sh`. Constraint: docs-only change, no runtime edits; guides must not diverge from code.

## Goals / Non-Goals

**Goals:**
- Three-layer docs: 5-min quickstart, full setup reference, full usage reference, all linked from `README.md`.
- Every snippet runnable as written; setup defaults match `config/runtime.exs`.

**Non-Goals:**
- No runtime, API, or config changes; no new Mix tasks or MCP tools.
- No video, translations, or hosted docs site; no rewrite of `docs/agents.md` beyond cross-links.

## Decisions

- **Three files (`QUICKSTART`/`SETUP`/`USAGE`) over one mega-guide:** quickstart must stay scannable; setup (operator) and usage (daily) have different readers. Alternative single `GUIDE.md` rejected — repeats the current README problem.
- **`README.md` becomes index, not copy:** keep Features + 15-line Quick Start + links; move config tables and agent details to links. Alternative full duplicate rejected — guarantees drift.
- **Reuse, don't restate agent setup:** `USAGE.md` summarizes MCP/CLI/WebSocket and links `docs/agents.md` as canonical for editor snippets. Alternative copying snippets rejected — two sources for `command` shape already diverge once.
- **Verification by execution, not eyeballing:** each snippet checked against `AgentDb` facade and `mix agent_db.* --help` output; env table checked against `config/runtime.exs`. Alternative review-only rejected — README already documents a broken `POST /api/v1/search` path unseen.

## Risks / Trade-offs

- [Risk] Guides drift from code after merge → Mitigation: review checklist runs every snippet; README points to guides so fixes land in one place.
- [Risk] Trimming README removes something users bookmarked → Mitigation: keep headings as anchor links to new files for one release cycle; no URL changes outside repo.
- [Risk] Quickstart bloats past 5 minutes → Mitigation: spec scenario enforces section allowlist; full detail lives behind next-step links.

## Migration Plan

Docs only: add three files, edit `README.md` links. Rollback is `git revert`. No migration, no feature flag.

## Open Questions

None — scope, file paths, and verification approach are fixed by specs.
