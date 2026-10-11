# Tasks

## 1. Facade and presentational components

- [x] 1.1 Add `Context.get_layers/1` returning per-layer `{text, source, chars}` (stored / fallback / unavailable) via existing `AgentDb` reads and verify with `mix test test/agent_db_web/context_test.exs` or equivalent facade test.
- [x] 1.2 Add `AdminComponents` LLM-layer card (labeled L0/L1/L2 sections with source badge, char count, unavailable state, excerpt + expand) and verify by rendering it in a LiveView test with stored, fallback, and unavailable inputs.

## 2. Document LLM view

- [x] 2.1 Extend `DocumentEditorLive` with an "How the LLM sees this document" section using `get_layers/1`, keeping draft guard (dirty draft never rewritten, layers refresh display-only) and verify `mix test test/agent_db_web/live/document_editor_live_test.exs` passes plus a new test asserting all three layers render with badges and counts.
- [x] 2.2 Cover refresh behavior (change event + periodic fallback reload layers without touching unsaved draft; missing layer shows unavailable) and verify with LiveView tests simulating `{:context_changed, ...}` and `:refresh`.

## 3. Skill LLM view

- [x] 3.1 Add per-row LLM-view toggle in `SkillsLive` loading files via existing `Context.list_all_documents(scope: skill_uri, page, per_page: 50)` with per-file `get_layers/1` excerpts and verify `mix test test/agent_db_web/live/admin_live_test.exs` passes plus a new test for expand/collapse and paged file listing.
- [x] 3.2 Cover skill replacement/removal convergence (open LLM view updates on change event / periodic refresh) and unavailable-file states, verified by LiveView tests.

## 4. Integration and styling

- [x] 4.1 Rebuild/verify console stylesheet includes new card classes via the documented asset build and verify pages render styled (`mix test` for stylesheet + manual load of `/admin/documents/:id/edit` and `/admin/skills`).
- [x] 4.2 Run full console-related suite (`mix test test/agent_db_web/live/`) and verify no regressions in navigation, trust boundary (`/admin/*` only, facade-only reads), and existing editor/skills behavior.
