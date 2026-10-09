# Design

## Context

See `proposal.md` — Why. Constraints that shape the approach:

- `AdminLive` currently owns everything: mount/subscribe/coalesce/fallback refresh, all event handlers, all data loading, and a 12-section template that delegates presentation to `AgentDbWeb.AdminComponents` (647 lines of function components). The section components already take their data as attributes and never call the store, so they move to pages unchanged.
- The web layer may reach the store only through `AgentDbWeb.Context`; `boundaries_test.exs` enforces that no `lib/agent_db_web/**/*.ex` module aliases a store/model/queue module. Every new page must keep this boundary.
- `assets/css/app.css` already defines `.admin-sidebar`, `.admin-content`, `.tab-nav`, `.badge*`, `.editor-pane`, `.document-tree` — scaffolding for a multi-page console that was never wired. `assets/tailwind.config.js` scans `../lib/**/*.ex` and `../lib/**/*.heex`, so any markup in a LiveView is picked up by a rebuild.
- `priv/static/assets/app.css` is committed and served, but was last built on 2026-09-18, before the current components existed: it lacks `space-y-8` and `grid-cols-5`, which the console markup uses. There is no `assets.build` alias and no dev watcher, so `mix` never regenerated it. This is the layout defect.
- The endpoint serves assets statically and the browser pipeline is unchanged: `:accepts html`, session, CSRF, `SessionAuth`. There is no `:put_root_layout`, so the layout function named by `use Phoenix.LiveView, layout: {AgentDbWeb.Layouts, :live}` produces the whole HTML document.

## Goals / Non-Goals

**Goals:**
- Five task-scoped console pages with a persistent sidebar and soft navigation, each loading only what it shows.
- One shared console lifecycle (subscribe, coalesce, fallback refresh) rather than four copies.
- Reuse the existing section components and the existing unused layout CSS.
- Make the console stylesheet current and reproducible.

**Non-Goals:**
- No new store data, facade functions, or `Context` functions; every value shown already exists.
- No change to the browser pipeline, auth, CSRF, or the editor's publish behavior.
- No new dependencies; no design-system overhaul beyond the console shell.
- No change to realtime delivery semantics in `context-subscriptions`.

## Decisions

### 1. Page set and module layout

Five LiveViews under a new `AgentDbWeb.Admin` namespace, replacing `AgentDbWeb.AdminLive`:

| Route | Module | Sections |
| --- | --- | --- |
| `/admin` | `AgentDbWeb.Admin.OverviewLive` | health, models, queue, runtime, recent changes |
| `/admin/documents` | `AgentDbWeb.Admin.DocumentsLive` | paged tree listing, search |
| `/admin/storage` | `AgentDbWeb.Admin.StorageLive` | footprint, cache, index coverage |
| `/admin/skills` | `AgentDbWeb.Admin.SkillsLive` | Agent Skills import |
| `/admin/sessions` | `AgentDbWeb.Admin.SessionsLive` | session lookup |

`/admin/documents/:id/edit` keeps `AgentDbWeb.DocumentEditorLive`. Section components stay in `AgentDbWeb.AdminComponents`.

*Alternatives:* keeping `AdminLive` as the overview and adding four views (rejected — an "AdminLive" that is only the overview while siblings are named for their page is inconsistent); one module with a `page` param (rejected — the current single-view problem, just parameterized).

### 2. A shared `AgentDbWeb.Admin` page macro owns the console lifecycle

`use AgentDbWeb.Admin` (new module) is the console's counterpart to `AgentDbWeb.__using__(:live_view)`. It:

- sets `layout: {AgentDbWeb.Layouts, :admin}`,
- subscribes to `viking://` on `connected?` mount and schedules the `@refresh_ms` fallback timer,
- owns `handle_info` for `:refresh`, `:refresh_coalesced`, and `{:context_changed, uri, kind, version}`, applying the existing coalescing window and maintaining the bounded recent-change feed,
- assigns the shared state (`recent_changes`, `last_reload_ms`, `reload_pending`, `notice`, `active`),
- calls the page's `load/1` to (re)load page-specific sections.

Pages implement `load/1` (their live sections), `handle_event/3` (their forms), and `render/1`; a page sets a module attribute naming its nav entry so `active` is assigned without each page repeating it. `mount/3` and `handle_params/3` are `defoverridable` so `DocumentsLive` can add `?page=` handling. This is the one place the console's realtime behavior lives, so it cannot drift between pages.

*Alternatives:* a plain helper module each page calls from its own `mount`/`handle_info` (rejected — duplicates the message handling in four modules); an `on_mount` hook (rejected — `on_mount` runs before `connected?` is useful and cannot own `handle_info`).

### 3. The admin shell is a layout function, navigation a component

`AgentDbWeb.Layouts.admin/1` renders the full HTML document (as `:live/1` does today) with a sidebar built from the existing `.admin-sidebar` / `.admin-content` classes plus Tailwind utilities. The nav lists the five pages, marks `@active`, and uses `<.link navigate={...}>`. `DocumentEditorLive` also adopts `:admin` so the sidebar persists into the editor, with Documents marked active.

Console routes are wrapped in `live_session :admin` in the router so `<.link navigate>` between pages is a soft navigation that reuses the connection instead of a full page load.

*Alternatives:* a `live_render`-based persistent shell with page content swapped in (rejected — larger, non-idiomatic, and the framework's `live_session` already gives soft navigation); per-page inline sidebars (rejected — duplicated markup).

### 4. Realtime scope per page

All console pages share the lifecycle, but only pages that render live store state show it changing: Overview (health, models, queue, runtime, feed), Documents (listing), Storage (counts/coverage). Skills and Sessions are operator-driven forms whose state is working state; their `load/1` is a no-op, so the shared refresh touches nothing they own. Search results, import results, and session messages remain working state that a reload never clears — the existing behavior, preserved by keeping them out of `load/1`.

### 5. Fix the stylesheet at its source

Add an `assets.build` alias (`tailwind default` + `esbuild default`) to `mix.exs`, document it, and rebuild and commit `priv/static/assets`. Because `tailwind.config.js` already scans `lib/**/*.ex`, a rebuild after this change emits the classes the new pages use. Optionally add dev watchers to the endpoint so `mix phx.server` keeps assets current; the alias is the requirement, watchers are convenience.

*Alternatives:* running the Tailwind/esbuild tasks by hand and committing (rejected — not reproducible or discoverable, which is how the assets went stale); moving to a runtime CDN (rejected — adds a network dependency to an offline-first tool).

### 6. Tests move with the sections

`admin_console_test.exs` and `admin_live_test.exs` retarget each assertion to the page that now owns the section (documents/paging/search → `/admin/documents`; storage/cache/index → `/admin/storage`; import → `/admin/skills`; session lookup → `/admin/sessions`; health/models/queue/runtime/feed → `/admin`). A new test asserts the navigation is present on each page and marks the current page.

## Risks / Trade-offs

- [Four subscriptions/timers instead of one] → Only pages showing live state do work on refresh; the shared lifecycle makes the cost uniform and bounded, and idle pages have a no-op `load/1`.
- [Soft navigation requires `live_session`] → Wrap all console routes in one `live_session`; if a page is opened by a direct URL it still mounts normally.
- [Retargeting tests could weaken coverage] → Move each existing assertion to its new page rather than dropping it; add navigation coverage; run the full suite.
- [Rebuilt assets are committed binaries] → They already are; the change keeps that model and adds the command that reproduces them.
- [Editor adopting the sidebar changes its layout] → Intended; the editor's publish/edit behavior is unchanged and covered by existing tests.

## Migration Plan

Additive routing and presentation; no data or config migration. Land the shared `AgentDbWeb.Admin` macro and shell, then the pages and router, then retarget tests, then rebuild assets. Rollback: revert the change and the committed assets; no schema or stored data is touched.

## Open Questions

- None that change the specs, approach, or task breakdown. Whether to add dev asset watchers is a convenience call left to implementation.
