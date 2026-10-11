# Design

## Context

See proposal.md Why. `AgentDb.Skills.Source` is the single owner of "what a bundle holds": three loaders (`{:path}` disk walk via `descend/4`, `{:archive}` member listing via `read_row/2`, `{:uploads}` via `add_upload/2`) accumulate bounded entries, then `finish/2` runs duplicate/conflict/layout checks. A `._SKILL.md` sidecar is binary, so `check_utf8` (disk/uploads) refuses the whole source today. Reproduced exactly with the reporter's folder.

## Goals / Non-Goals

**Goals:**
- Folders/archives/selections containing AppleDouble/`._*` or `.DS_Store` import the real skills; metadata never stored, never budgeted, never layout-checked.

**Non-Goals:**
- No new refusal reasons, no skipped-file reporting channel, no change to limits or stored-file semantics.

## Decisions

- **Skip by basename at each loader's entry point, before normalization/counting.** Disk: in `descend/4`, ignore a child whose name is metadata (files and dirs — never descend into metadata dirs). Archive: in `read_row/2`, ignore members whose last segment is metadata. Uploads: in `add_upload/2`, ignore paths whose last segment is metadata. Rationale: one predicate, three call sites, same single-ownership module; skipping before counting keeps Finder droppings out of the bundle budget and before normalization keeps odd-byte sidecars from tripping path validation. Alternative (filter after accumulation) rejected: spreads budget/layout special-cases through `finish/2`.
- **Predicate: basename starts with `._`, or equals `.DS_Store`.** Rationale: covers AppleDouble sidecars for files and dirs plus Finder store files — the two artifacts that actually appear inside user folders. Alternative (broader dotfile ignore) rejected: dotfiles like `.env` or `.gitignore` can be legitimate skill content; only OS-owned names are set aside.
- **Silent set-aside, documented in moduledocs.** Rationale: no warnings channel exists in the `import_skills` return shapes; adding one would churn UI/CLI/JSON surfaces for noise. Trade-off recorded: a skill file genuinely named `._x` would be dropped — accepted as vanishingly unlikely vs. every Finder-touched folder failing today.

## Risks / Trade-offs

- [Risk] Operator-authored `._*` content silently dropped → Mitigation: documented in `Source` moduledoc and Mix task help; predicate limited to OS-owned names.
- [Risk] Metadata-only source errors read differently per shape (`no_skills` vs `missing_manifest`) → Mitigation: existing refusal paths, no new error; covered by test.

## Migration Plan

None. Fewer refusals, no schema/config/API change. Rollback is revert.
