# Design

## Context

See proposal.md Why. `SkillsLive` configures uploads with `allow_upload` defaults (`auto_upload: false`) and the form binds only `phx-submit`. LiveView starts client uploads and roundtrips selection state only via change events or auto-upload; with neither, selection is held client-side invisibly. Submit-time preflight still works, but the operator gets zero feedback and assumes breakage. Constraints: import/consume semantics unchanged; entry errors must surface at the form.

## Goals / Non-Goals

**Goals:**
- Selection immediately lists entries with progress and errors; submit path byte-identical.

**Non-Goals:**
- No validation, limit, result-reporting, or storage changes.

## Decisions

- **Add `phx-change="validate"` + no-op validate event, and `auto_upload: true` on both configs.** Rationale: the standard LiveView uploads pattern — change roundtrip renders entries/errors, auto-upload streams bytes with progress, submit consumes completed entries through the untouched `read_source` path. Alternative (phx-change only, uploads on submit) rejected: still shows 0% until submit, weaker feedback for folder selections.
- **Validate event ignores params and consumes nothing.** Rationale: consumption stays exactly once, on submit; validate is render-only so it cannot double-consume or disturb entries.

## Risks / Trade-offs

- [Risk] Unsubmitted auto-uploads use temp space until disconnect-cleanup → Mitigation: standard LiveView lifecycle; entries are small text, bounded by existing caps.
- [Risk] Mid-upload submit waits for completion → Mitigation: framework behavior with visible progress; unchanged from submit-preflight today.

## Migration Plan

None. Form bindings + upload flags only.
