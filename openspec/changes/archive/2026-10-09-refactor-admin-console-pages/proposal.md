# Proposal

## Why

The operations console at `/admin` is one `AdminLive` that stacks all eleven sections in a single vertical column with no navigation, so an operator cannot find or focus on the task at hand. The layout is also visibly broken: `priv/static/assets/app.css` was last built before the current components existed, so Tailwind utility classes the console uses (`space-y-8`, `grid-cols-5`) were never generated, and there is no asset build alias or dev watcher to regenerate it.

## What Changes

- **Split the console into five pages under `/admin/*`**, grouped by operator task, each a LiveView that loads and refreshes only the data it shows:
  - `/admin` — Overview: health, models, queue, runtime, recent-change feed.
  - `/admin/documents` — document tree listing (paged) and document search.
  - `/admin/storage` — storage footprint, cache, index coverage.
  - `/admin/skills` — Agent Skills import.
  - `/admin/sessions` — session lookup by ID.
- **Add a persistent sidebar layout** shared by the console pages (and the document editor at `/admin/documents/:id/edit`), with the active page highlighted. Navigation between console pages uses `live_session` soft navigation.
- **Preserve realtime behavior per page**: each page that shows live store state subscribes to `viking://` on connect and coalesces reloads, retaining the periodic fallback refresh. The recent-change feed lives on Overview.
- **Fix the broken assets**: provide a supported way to build the console CSS/JS (a `mix assets.build` alias and/or dev watchers) and rebuild `priv/static/assets` so the utility classes the console uses are present.
- **Keep the trust boundary unchanged**: same `:browser` pipeline, same `SessionAuth`, same `AgentDbWeb.Context` facade only, no new store access path, no new dependencies.
- **BREAKING (tests only)**: existing tests that mount `/admin` and assert every section now target the page that owns the section; assertions move with the sections.

## Capabilities

### New Capabilities

<!-- None. The console remains the single `admin-dashboard` capability. -->

### Modified Capabilities

- `admin-dashboard`: the console becomes a navigable multi-page surface. Requirements change from "one console page that shows everything" to "a set of task-scoped pages with a shared navigation/layout, with each feature still available and realtime behavior preserved." Routing/layout behavior is externally observable, so it is specified here.

## Impact

- `lib/agent_db_web/router.ex` — replace the single `live("/admin", AdminLive, :index)` with a `live_session` of console routes; keep the editor route.
- `lib/agent_db_web/live/admin_live.ex` — replaced by per-page LiveViews (Overview, Documents, Storage, Skills, Sessions); shared lifecycle (subscribe, coalesce, fallback refresh) extracted so it is not duplicated.
- `lib/agent_db_web/live/admin_components.ex` — presentation components reused by the pages; add the sidebar/shell component.
- `lib/agent_db_web/layouts/live.ex` — add the admin shell layout (or a sibling layout module).
- `assets/` and `priv/static/assets/` — add the build path for console assets and rebuild them.
- `test/agent_db_web/live/admin_live_test.exs`, `test/agent_db_web/live/admin_console_test.exs` — retarget assertions to the owning page; add navigation coverage.
- No change to the `AgentDb` facade, auth plugs, REST/WebSocket/MCP contracts, or database schema. No new dependencies.
