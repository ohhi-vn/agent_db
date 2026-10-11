# Tasks

## 1. Store metadata, migration, and lifecycle consistency

- [x] 1.1 Widen `nodes` with `enabled`/`group_tag` (DDL + `@added_columns` + indexes) and verify a pre-change DB opens with old rows reading enabled/ungrouped via `mix test test/agent_db/store_test.exs` (or nearest store test).
- [x] 1.2 Implement subtree `set_enabled`/`set_group` bulk updates with write-path inheritance and `Cache.invalidate_removal`, and verify toggle → cached read and store read agree via new store tests.
- [x] 1.3 Preserve `enabled`/`group_tag` across skill replace and clear them on subtree removal, and verify replace-keeps-status/group plus remove-clears-tags via `mix test test/agent_db/skills_test.exs`.
- [x] 1.4 Classify group-tag validation (`{:invalid_group, tag}` via shared taxonomy, no raw terms) and verify invalid tags are refused with prior tag unchanged via unit tests.

## 2. Search, listing, and inventory filtering

- [x] 2.1 Filter keyword `search`, `find`, `grep`, and memory recall to enabled-only by default with explicit disabled-included opt-in, and verify disabled URIs vanish from defaults but return with opt-in via store/search tests.
- [x] 2.2 Add vector over-fetch + store-side enabled/group post-filter and hybrid fusion over filtered sets, and verify hybrid/vector exclude disabled by default via search tests (skip when sqlite-vec unavailable, asserting the unavailable path instead).
- [x] 2.3 Implement recursive paged show-all listing (50/page default, max 200, invalid-page clamp, substring/group/status filters, `COUNT(*)` totals, no blob materialization) and verify pagination/filter/counts via store tests.
- [x] 2.4 Implement skill inventory aggregation (roots at `user/{id}/skills/{name}` with owner/URI/file-count/status/group) with paged search, and verify multi-user listing and name search via new inventory tests.

## 3. Facade (`AgentDb` + `AgentDbWeb.Context`)

- [x] 3.1 Expose `AgentDb.set_enabled/set_group/bulk` + `list_all_documents/list_skills` with notifications (`:replaced`-style events so realtime reloads), and verify events fire and status changes converge without restart via facade tests.
- [x] 3.2 Expose matching `Context` helpers shaping facade results for LiveViews (paging metadata, classified `error_message`), and verify `mix test test/agent_db_web/context_test.exs` passes plus invalid input renders classified reasons.

## 4. Admin console (Documents + Skills pages)

- [x] 4.1 Extend Documents page with show-all mode, substring/scope filter, group/status filters, per-row status/group display, single + bulk enable/disable and group assignment with summary counts, and verify `mix test test/agent_db_web/live/admin_console_test.exs` passes plus new show-all/toggle/group tests.
- [x] 4.2 Extend Skills page with inventory table (owner/URI/files/status/group), skill search, show-all paging, and single + bulk enable/disable/group alongside the unchanged import form, and verify import still reports per-skill outcomes plus new inventory/toggle tests.
- [x] 4.3 Add `AdminComponents` listing/group/toggle rows reusing `page_of` clamping, realtime `load/1` reload, classified feedback (no `inspect`), and stylesheet-covered classes, and verify `mix test test/agent_db_web/live/admin_components_test.exs` passes and `mix assets.build` (documented command) includes new classes.
- [x] 4.4 Keep trust boundary (no new routes/auth, `/admin/*` browser pipeline only, facade-only store access) and verify navigation marks current page and editor links still resolve via `mix test test/agent_db_web/live/admin_navigation_test.exs`.

## 5. Integration and regression

- [x] 5.1 Run full verification (`mix test`, `mix lint` or CI equivalent per `guides/SETUP.md#verifying-a-change`) and verify zero failures, documenting any pre-existing failures left untouched.
