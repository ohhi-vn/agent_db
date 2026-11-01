# Design

## Context

The admin console is a Phoenix LiveView surface served under `/admin/*` (see
`lib/agent_db_web/layouts/live.ex`, `lib/agent_db_web/live/admin.ex`,
`lib/agent_db_web/live/admin_components.ex`, and the six page modules under
`lib/agent_db_web/live/admin/`). Styling is Tailwind v3 via the `tailwind`
and `esbuild` Mix tasks, configured in `config/config.exs` and
`assets/tailwind.config.js`, with a hand-written `assets/css/app.css` that mixes
Tailwind directives, Phoenix LiveView defaults, and a bespoke `admin-card-*`
accent system. Generated CSS lands in `priv/static/assets/app.css` via
`mix assets.build`. See `proposal.md` for motivation.

## Goals / Non-Goals

**Goals:**
- Adopt daisyUI as the single component vocabulary for the console, keeping
  Tailwind as the utility foundation.
- Preserve all existing behavior: routes, events, data loading, realtime refresh,
  sidebar toggle/state, pagination, flash feedback.
- Keep the build reproducible through `mix assets.build` / `mix assets.deploy`.
- Retain genuinely custom rules (document tree, editor panes, LLM layer
  excerpts) that daisyUI does not provide.

**Non-Goals:**
- No new pages, data sources, or store-facing behavior.
- No migration to a different CSS framework or build tool.
- No JavaScript framework changes; LiveView + esbuild stay.
- No dark-mode-first theming; light theme is the default, dark is optional/future.

## Decisions

### D1: daisyUI as a Tailwind plugin (npm), not a CDN

- **Choice:** Add `daisyui` to `assets/package.json` and register it in
  `assets/tailwind.config.js` under `plugins: [require("daisyui")]`.
- **Rationale:** The project already ships a Tailwind/Node pipeline and commits
  generated CSS under `priv/static`. A plugin keeps the single-source build
  (`mix assets.build`) and the digest step (`phx.digest`) working unchanged. A
  CDN would split asset ownership and break offline/air-gapped deployments, which
  conflicts with the "fully local" product stance.
- **Alternatives considered:** CDN link in the layout (rejected: offline + CSP);
  copying daisyUI CSS into `app.css` (rejected: loses theming and upgrades).

### D2: Single light theme by default, theme attribute on `<html>`

- **Choice:** Configure daisyUI with `themes: ["light"]` (and optionally
  `"dark"` later) and set `data-theme="light"` on the `<html>` element in the
  admin layout. No runtime theme toggle in this change.
- **Rationale:** Keeps scope to a visual redesign; a theme toggle is a separate
  feature and would add state/events. The `data-theme` attribute keeps the door
  open without code changes.
- **Alternatives considered:** Multi-theme with a toggle button (deferred).

### D3: Component mapping (bespoke → daisyUI)

| Current (bespoke) | daisyUI replacement | Notes |
|---|---|---|
| `admin-card` + `admin-card-*` accent | `card bg-base-100 shadow` with `card-title` + a colored `border-t-4` accent utility retained for section identity | Keep per-section color identity via a small set of utility classes to preserve scannability |
| `admin-header` gradient bar | `navbar bg-primary text-primary-content` | Sticky top |
| `admin-sidebar` + nav links | `drawer`/`menu` with `menu-active` for the current page | Preserve `toggle_sidebar` event and `data-sidebar` attribute for CSS show/hide |
| Buttons (`bg-blue-600 ...`) | `btn btn-primary` / `btn btn-ghost` / `btn btn-error` (ghost) | Destructive actions use `btn-error btn-outline` |
| Inputs | `input input-bordered` | Monospace via `font-mono` where needed |
| Badges (`.badge-*`) | `badge badge-success/warning/error/info/ghost` | Source badges (`stored`/`fallback`) map to success/warning/ghost |
| Tabs (`.tab-nav`) | `tabs tabs-bordered` | |
| Flash (`.flash-*`) | `alert alert-success/error/info` | Keep `aria-live` region |
| Status pills (enabled/disabled) | `badge badge-success/ghost` | |

- **Rationale:** One-to-one mapping keeps diffs reviewable and behavior identical;
  daisyUI's component classes are the documented, accessible defaults.
- **Alternatives considered:** Rewriting components from scratch with custom
  Tailwind (rejected: defeats the purpose of adopting a library).

### D4: Sidebar show/hide keeps CSS-driven mechanism

- **Choice:** Retain the `#admin-shell[data-sidebar="hidden"] .admin-sidebar
  { display: none; }` rule and the `toggle_sidebar` event; only the classes on
  the sidebar element change to daisyUI's `menu` styling.
- **Rationale:** The mechanism is tested/ relied upon for "without a full page
  reload" and session persistence. Changing to JS-driven drawer state would risk
  regressions and is out of scope.

### D5: Retain custom CSS for non-component visuals

- **Choice:** Keep in `app.css`: Phoenix LiveView defaults (`.phx-*`), document
  tree (`.document-tree`), editor panes (`.editor-pane`), LLM layer excerpts,
  and the sidebar show/hide rule. Remove the bespoke card/header/badge/tab/flash
  rules once migrated.
- **Rationale:** These are domain-specific visuals daisyUI does not model;
  removing them would break the editor and document tree pages.

### D6: Incremental, page-by-page migration within one change

- **Choice:** Migrate components first (shared primitives), then the shell
  layout, then each page module, then delete obsolete CSS. Single PR/change.
- **Rationale:** Shared components are the bottleneck; migrating them first
  unblocks pages. Keeping it one change avoids a half-migrated intermediate
  state in `main`.

### D7: daisyUI version pinning

- **Choice:** Pin to a specific daisyUI minor (e.g. `^4.x`) in `package.json`
  and commit the updated lockfile. Document the version in a comment in
  `tailwind.config.js`.
- **Rationale:** Reproducible builds; daisyUI occasionally changes default
  theme tokens between majors.

## Risks / Trade-offs

- [daisyUI class names conflict with existing custom classes] → Migrate
  incrementally and run `mix assets.build` + the test suite after each page;
  remove obsolete CSS only after grep confirms no references.
- [Tailwind content scanning misses daisyUI classes added via HEEx] → Ensure
  `content` globs in `tailwind.config.js` already cover `../lib/**/*.ex` and
  `../lib/**/*.heex` (they do); daisyUI's plugin adds its own safelist.
- [Generated `app.css` grows] → Acceptable; minified deploy build keeps size
  bounded; monitor in CI.
- [Tests assert on specific class strings] → Update assertions to new classes
  where they test presentation; keep behavioral assertions unchanged.
- [Accessibility regressions] → daisyUI components are accessible by default;
  verify focus rings and `aria-*` attributes in the shell and forms during review.
- [Dark mode not delivered] → Out of scope; light theme only.

## Migration Plan

1. Add daisyUI to `assets/package.json`; run `npm install` in `assets/`.
2. Update `assets/tailwind.config.js` (plugin + theme) and `assets/css/app.css`
   (import daisyUI base; trim obsolete rules).
3. Migrate shared primitives in `admin_components.ex` (flash, nav, cards,
   buttons, inputs, badges, tabs).
4. Migrate shell in `layouts/live.ex`.
5. Migrate each page module's markup.
6. Remove now-unused custom CSS; run `mix format` and `mix assets.build`.
7. Run `mix assets.deploy` to regenerate digested assets; verify no 404s.
8. Update affected tests; run full test suite and `mix lint:quick`.

**Rollback:** Revert the change commit; regenerate assets via `mix assets.build`.
No data migration; store state untouched.

## Open Questions

- Whether to enable daisyUI's `dark` theme in this change or defer. (Deferred;
  light-only for now.)
- Exact daisyUI minor version to pin. (Resolve at implementation time based on
  latest stable.)