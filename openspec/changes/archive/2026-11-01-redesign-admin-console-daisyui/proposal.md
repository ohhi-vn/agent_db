# Proposal

## Why

The admin console's visual layer has grown organically: hand-rolled Tailwind utilities
mixed with a bespoke `admin-card-*` accent scheme, custom badges, tabs, and flash
classes duplicated across `admin_components.ex` and `layouts/live.ex`. The result is
inconsistent spacing, color, and component affordances across the six console pages,
and every new section re-invents the same primitives. A full visual redesign on a
single, documented component library (daisyUI) will make the console clearer to
operate, consistent across pages, and cheaper to extend, without changing what it
does.

## What Changes

- Adopt **daisyUI** as the console's component library, layered on the existing
  Tailwind CSS pipeline (no new build toolchain beyond an npm dependency).
- Replace the bespoke `admin-card-*` accent scheme, custom badges, tabs, buttons,
  inputs, and flash styling with daisyUI component classes (`card`, `btn`, `input`,
  `badge`, `tabs`, `alert`, `drawer`/`menu`).
- Redesign the console shell in `layouts/live.ex`: header bar, hideable sidebar,
  and content region using daisyUI's `drawer` + `navbar` primitives while keeping
  the existing `toggle_sidebar` event and session-persisted sidebar state.
- Restyle every section in `admin_components.ex` (overview, documents, storage,
  skills, sessions, memories, search, models, queue, health, runtime, operation
  stats, footprint, indexes, memory stats/candidates, import, recent changes) to
  the new component vocabulary.
- Restyle page-level markup in each `admin/*_live.ex` (headers, notices, spacing)
  to match the new shell.
- Update `assets/tailwind.config.js` to register the daisyUI plugin and choose a
  theme (light default, dark optional), and update `assets/css/app.css` to import
  daisyUI and retain only genuinely custom rules (document tree, editor, LLM
  layers).
- Update the asset build so `mix assets.build` / `mix assets.deploy` continue to
  reproduce the stylesheet; add daisyUI to `assets/package.json` and the lockfile.
- Refresh generated `priv/static/assets/app.css` via the documented build command.
- Update any tests that assert on console markup/CSS classes if needed (behavior
  assertions remain unchanged).

No routes, controllers, LiveView events, data loading, or store-facing behavior
change. The console keeps serving under `/admin/*` with the same protections.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

(none — this is a presentation-only redesign; all functional requirements in
`admin-dashboard` remain satisfied unchanged, including sidebar toggle, header bar,
realtime refresh, pagination, and stylesheet build reproducibility.)

This change opts out of spec deltas (`skip_specs: true` in `.openspec.yaml`).

## Impact

- Affected code: `assets/css/app.css`, `assets/tailwind.config.js`,
  `assets/package.json`, `lib/agent_db_web/layouts/live.ex`,
  `lib/agent_db_web/live/admin_components.ex`, all `lib/agent_db_web/live/admin/*_live.ex`,
  generated `priv/static/assets/app.css`.
- Dependencies: adds `daisyui` npm package (Tailwind plugin); no new Elixir deps.
- APIs: none changed.
- Tests: presentation/selector-based tests may need updates; behavioral tests unaffected.