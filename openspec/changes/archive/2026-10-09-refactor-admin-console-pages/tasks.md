# Tasks

## 1. Reproducible console asset build

- [x] 1.1 Add an `assets.build` alias to `mix.exs` that runs the project's Tailwind and esbuild builds, and verify `mix assets.build` exits successfully
- [x] 1.2 Run `mix assets.build` and confirm the rebuilt `priv/static/assets/app.css` now contains the classes the console markup uses (`space-y-8`, `grid-cols-5`), which the stale build was missing
- [x] 1.3 Document the asset build command in `README.md` (console/development section) and verify the documented command is the one that reproduces `priv/static/assets`

## 2. Shared console lifecycle and shell

- [x] 2.1 Add `AgentDbWeb.Admin`, a `use` macro that sets the admin layout, subscribes to `viking://` on connect, schedules the fallback refresh, owns `handle_info` for `:refresh` / `:refresh_coalesced` / `{:context_changed, _, _, _}` with the existing coalescing window and bounded recent-change feed, assigns shared state, and calls the page's `load/1`; verify it compiles and `mix lint:quick` passes
- [x] 2.2 Add the admin shell layout `AgentDbWeb.Layouts.admin/1` and the sidebar navigation component (using the existing `.admin-sidebar` / `.admin-content` classes), listing Overview, Documents, Storage, Skills, Sessions and marking the active page; verify with a component test that all five links render and the active page is marked

## 3. Overview page

- [x] 3.1 Create `AgentDbWeb.Admin.OverviewLive` using `AgentDbWeb.Admin`, loading health, models, queue detail, runtime, and recent changes; add a `live_session :admin` to `AgentDbWeb.Router` routing `/admin` to it, and remove the now-unused `AgentDbWeb.AdminLive`
- [x] 3.2 Retarget the model/queue/health assertions and the failed-job assertions from `admin_console_test.exs` and the "model, queue and health status" block from `admin_live_test.exs` to `/admin`; verify those tests pass
- [x] 3.3 Retarget the realtime-update tests (feed entries, burst ordering, fallback refresh, no content in feed) to `/admin`; verify they pass
- [x] 3.4 Update the `README.md` console description to name the five pages and the sidebar navigation; verify it matches the routes actually served

## 4. Documents page

- [x] 4.1 Create `AgentDbWeb.Admin.DocumentsLive` using `AgentDbWeb.Admin`, with `handle_params` for `?page=`, the paged tree-root listing, the total document count, document search, and remove; add its route under `live_session :admin`
- [x] 4.2 Retarget the "document count", "paging", search, and delete assertions from the two console test files to `/admin/documents`; verify they pass
- [x] 4.3 Verify the documents page still links each listing/search hit to `/admin/documents/:id/edit`

## 5. Storage page

- [x] 5.1 Create `AgentDbWeb.Admin.StorageLive` using `AgentDbWeb.Admin`, loading storage footprint, cache, and index coverage; add its route under `live_session :admin`
- [x] 5.2 Retarget the storage-composition, cache, and index-coverage assertions (including the unavailable-vector-index case) to `/admin/storage`; verify they pass

## 6. Skills page

- [x] 6.1 Create `AgentDbWeb.Admin.SkillsLive` using `AgentDbWeb.Admin`, with the skill upload setup, `import_skills` event, and result rendering; add its route under `live_session :admin`
- [x] 6.2 Retarget the skill-import tests (field names/limits, folder import, replacement, archive, refusal, empty selection) to `/admin/skills`; verify they pass

## 7. Sessions page

- [x] 7.1 Create `AgentDbWeb.Admin.SessionsLive` using `AgentDbWeb.Admin`, with the `lookup_session` event and message rendering; add its route under `live_session :admin`
- [x] 7.2 Retarget the session-lookup assertions (known session, unknown session) to `/admin/sessions`; verify they pass

## 8. Editor, navigation integration, and full verification

- [x] 8.1 Move `AgentDbWeb.DocumentEditorLive` to the admin layout so the sidebar persists, marking Documents active; verify the editor's existing tests still pass
- [x] 8.2 Add an integration test that visits each console page and navigates between them via the sidebar, asserting each page's characteristic content and that navigation does not require a full reload; verify it passes
- [x] 8.3 Run the full suite (`mix test`) and the project lint gate (`mix lint`) and confirm both pass with the console refactor in place

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
