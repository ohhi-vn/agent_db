# Proposal

## Why

The daisyUI redesign of the admin console (`redesign-admin-console-daisyui`) landed
its shared primitives and shell, but the migration stopped short: several pages and
components still use the old bespoke Tailwind classes (`rounded bg-blue-50`,
`border border-gray-300`, `rounded bg-blue-600`, `bg-gray-50` body), the document
editor was not migrated at all, status text is uncolored, and the shell still
relies on raw gray/blue utilities instead of daisyUI's themed tokens. The result is
a console that is half daisyUI and half bespoke, so light/dark theming and
consistent status colors do not actually apply, and the visual theme requirement
in `admin-dashboard` is only partially satisfied.

## What Changes

- Finish the page-level migration: `overview_live.ex`, `documents_live.ex`,
  `storage_live.ex`, `skills_live.ex`, `sessions_live.ex`, `memories_live.ex`, and
  `document_editor_live.ex` switch their notices, headers, inputs, and buttons to
  daisyUI `alert`/`input`/`btn` classes.
- Migrate the remaining bespoke rules in `admin_components.ex` (skill-file chips,
  LLM layer excerpts) to daisyUI `badge`/`bg-base-200` tokens.
- Replace raw gray/blue Tailwind utilities in the shell and components with
  daisyUI semantic tokens (`base-100/200/300`, `base-content`, `primary`,
  `success`/`warning`/`error`/`info`) so the chosen theme applies consistently.
- Colorize status text (enabled/disabled, health ok/down, queue availability)
  using daisyUI status colors.
- Update the document editor's textarea, notice, and publish button to daisyUI
  classes and keep the editor's custom panes.
- Remove any CSS rules left unused by the completed migration and refresh the
  generated `priv/static/assets/app.css`.
- Add a small visual regression check (existing admin tests + stylesheet test)
  covering the migrated classes.

No routes, events, data loading, or store-facing behavior change. The console
keeps serving under `/admin/*` with the same protections.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

(none — this completes the presentation-only migration already specified by
`admin-dashboard`'s "Console uses a colorful clean visual theme" requirement;
no requirement text changes.)

This change opts out of spec deltas (`skip_specs: true` in `.openspec.yaml`).

## Impact

- Affected code: `lib/agent_db_web/live/*.ex`, `lib/agent_db_web/live/admin/*.ex`,
  `lib/agent_db_web/layouts/live.ex`, `assets/css/app.css`, generated
  `priv/static/assets/app.css`.
- Dependencies: none new (daisyUI already added).
- APIs: none changed.
- Tests: presentation assertions may need class-name updates; behavioral tests
  unchanged.