# Tasks

## 1. Header bar and collapsible sidebar shell

- [x] 1.1 Add persistent header bar to `AgentDbWeb.Layouts.admin/1` (brand, current-page title from `@active`, sidebar toggle `<button aria-controls="admin-sidebar" aria-expanded>`) and verify `mix test test/agent_db_web/live/admin_navigation_test.exs` passes with the header present on all five pages and the editor
- [x] 1.2 Add sidebar collapse behavior in `assets/js/app.js` + `assets/css/app.css` (toggle flips shell `data-sidebar`, hides `<aside id="admin-sidebar">`, expands content, persists to `localStorage`, re-applies on `phx:page-loading-stop`) and verify by loading `/admin`, toggling hide/show without reload, and navigating to `/admin/documents` with the hidden state preserved
- [x] 1.3 Extend sidebar/nav component tests to cover the toggle and active-page marking in the new shell and verify `mix test test/agent_db_web/live/admin_components_test.exs test/agent_db_web/live/admin_navigation_test.exs` passes

## 2. Colorful clean visual theme

- [x] 2.1 Refresh `AgentDbWeb.AdminComponents` section cards (colored top accent per section kind, tinted card headers, consistent `.badge-*` status colors, `space-y-6 p-6` rhythm, no removed fields) and verify existing console render tests pass plus visual check of overview/documents/storage/skills/sessions pages
- [x] 2.2 Add theme styles to `assets/css/app.css`, rebuild with `mix assets.build`, and verify `mix test test/agent_db_web/live/admin_stylesheet_test.exs` passes and the generated `priv/static/assets/app.css` contains the new header/sidebar/card classes
- [x] 2.3 Keep flash feedback visible in the new theme (success/failure colors in header/content area) and verify `mix test test/agent_db_web/live/admin_console_test.exs` passes with feedback asserted on the page left on

## 3. Integration verification

- [x] 3.1 Run the full admin LiveView suite and lint (`mix test test/agent_db_web/live/ && mix lint:quick`) and verify all green with no realtime, routing, or trust-boundary regressions
