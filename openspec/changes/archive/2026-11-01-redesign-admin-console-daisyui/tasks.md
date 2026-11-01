# Tasks

## 1. Dependency and build setup

- [x] 1.1 Add `daisyui` to `assets/package.json` dependencies (pinned minor) and run `npm install` in `assets/`; verify `assets/node_modules/daisyui/package.json` exists and lockfile updated.
- [x] 1.2 Update `assets/tailwind.config.js` to register the daisyUI plugin and configure `themes: ["light"]`; verify `mix tailwind default` exits 0 and emits no plugin errors.
- [x] 1.3 Update `assets/css/app.css` to import daisyUI's base/components/utilities alongside Tailwind and remove obsolete bespoke card/header/badge/tab/flash rules; verify `mix assets.build` succeeds and `priv/static/assets/app.css` contains `.btn` and `.card` rules.
- [x] 1.4 Set `data-theme="light"` on the `<html>` element in the admin layout (`lib/agent_db_web/layouts/live.ex`); verify a rendered `/admin` page's root element carries the attribute.

## 2. Shared component migration

- [x] 2.1 Migrate `flash_group/1`, `sidebar/1`, and `nav_link/1` in `admin_components.ex` to daisyUI `alert` and `menu`/`navbar` classes; verify flash messages and sidebar toggle render and `toggle_sidebar` still works.
- [x] 2.2 Migrate card sections (recent changes, import skills, search, documents, documents_all, skills_inventory, session lookup, footprint, indexes, memory stats/candidates, models, queue, health, runtime, operation stats) from `admin-card-*` to daisyUI `card` + retained accent utility; verify each section renders with `card` class and no remaining `admin-card-sky` etc. references in migrated components.
- [x] 2.3 Migrate buttons, inputs, badges, and tabs to daisyUI `btn`/`input`/`badge`/`tabs` classes across `admin_components.ex`; verify forms submit and badges display correct variants.
- [x] 2.4 Remove now-unused bespoke CSS rules (card accents, badges, tabs, flash) from `assets/css/app.css` after grep confirms no references; verify `mix assets.build` succeeds and no `.admin-card-*` selectors remain.

## 3. Shell layout migration

- [x] 3.1 Migrate `layouts/live.ex` admin shell (header, sidebar, content region) to daisyUI `navbar`/`drawer` while retaining the `#admin-shell[data-sidebar]` show/hide rule and `toggle_sidebar` event; verify sidebar hides/restores without full reload and state persists across pages.
- [x] 3.2 Verify the header bar shows product identity, page title, and sidebar toggle on every console page including the document editor; verify via existing layout tests or a smoke request to each `/admin/*` route.

## 4. Page-level migration

- [x] 4.1 Migrate page markup in `overview_live.ex`, `documents_live.ex`, and `storage_live.ex` to the new shell spacing/typography; verify each page renders and data sections load once per visit.
- [x] 4.2 Migrate page markup in `skills_live.ex`, `sessions_live.ex`, and `memories_live.ex`; verify skill import, session lookup, and memory promote/reject/forget still function.
- [x] 4.3 Migrate the document editor live view (`document_editor_live.ex`) to the new stylesheet and layout; verify editor renders and edit/save works.

## 5. Tests and documentation

- [x] 5.1 Update presentation-level tests that assert on removed CSS class names to the new daisyUI classes; verify those tests pass.
- [x] 5.2 Update guides that reference console markup or asset build steps if affected (check `guides/MONITORING.md`); verify documented build command still runs.
- [x] 5.3 Add a short note to `guides/SETUP.md` (or equivalent) documenting the daisyUI dependency and theme; verify the note renders in `mix docs` without errors.

## 6. Integration verification

- [x] 6.1 Run `mix assets.deploy` and verify `priv/static/assets/app.css` is regenerated and digested without 404s on a local boot.
- [x] 6.2 Run `mix test` for the web/admin test suites and `mix lint:quick`; verify no failures introduced by the redesign.
- [x] 6.3 Manual smoke: boot the app, visit every `/admin/*` page, toggle sidebar, perform one document search and one skill import; verify no console errors and consistent styling.

## Workflow follow-up

- Archive the change after review requirements are satisfied.
- Verify the archived result.