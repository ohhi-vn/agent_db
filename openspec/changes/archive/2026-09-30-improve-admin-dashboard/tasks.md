# Tasks

## 1. Realtime console

- [x] 1.1 Subscribe `AdminLive` to `viking://` on connected mount and reload on `{:context_changed, uri, kind, version}` with bounded recent feed, and verify a LiveView test sending a change event updates the listing/feed without manual reload
- [x] 1.2 Keep the 30s refresh as fallback and coalesce rapid change bursts, and verify a missed-event run still converges on the next timer tick without reload storms

## 2. Richer operations info

- [x] 2.1 Add document search box (keyword default, scoped, top_k bounded) linking results to the existing editor with failure-in-words behavior, and verify a LiveView test for search success, pagination preserved, and failure-keeps-listing
- [x] 2.2 Render full model status (loading/in-progress, latency, memory, configured size), full job breakdown, and health checks, and verify a LiveView test asserts loading/latency/memory/queue/health output
- [x] 2.3 Add recent-change feed (URI, kind, version only, bounded) and session-by-ID lookup via existing facade, and verify a LiveView test for feed ordering/content-free payload and found/not-found session lookup

## 3. Structure and regression

- [x] 3.1 Extract additive `/admin/*` LiveViews only if `AdminLive` becomes unwieldy (same browser pipeline, facade-only), and verify `mix compile --warnings-as-errors` passes and routes remain `/admin` + additive paths
- [x] 3.2 Run console regression (`mix test test/agent_db_web/live/admin_live_test.exs`) plus new realtime/info tests, and verify existing skill-import/edit/delete scenarios still pass

## 4. Backend latency/memory read-out (Option 2 scope)

- [x] 4.1 Record per-role last inference latency and VM memory in `ModelManager.model_status`, and verify a FakeLoader unit test asserts an integer `last_latency_ms` after `embed/1` plus a present `memory_bytes`
- [x] 4.2 Render latency/memory in the `AdminLive` Models section with a not-reported fallback, and verify a LiveView test asserts the labels and values (which closes 2.2)
