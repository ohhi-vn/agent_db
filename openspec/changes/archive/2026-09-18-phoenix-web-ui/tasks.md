# phoenix-web-ui Tasks

## Setup & Configuration

- [x] Add Phoenix LiveView, LiveDashboard, Tailwind, esbuild to mix.exs deps
- [x] Configure `config/config.exs` for endpoint, router, LiveView, pubsub
- [x] Add `config/runtime.exs` for production secrets (signing salt, db url)
- [x] Create `assets/` directory with `package.json`, `tailwind.config.js`, `app.css`, `app.js`
- [x] Run `mix assets.setup && mix assets.build` to verify asset pipeline

## Router & Pipelines

- [x] Create `lib/agent_db_web/router.ex` with `:browser` and `:api` pipelines
- [x] Define routes: `/health`, `/api/v1/*`, `/admin/*`, `/dev/dashboard` (dev only)
- [x] Add CORS plug to `:api` pipeline
- [x] Add authentication plug to `:api` pipeline (Bearer token)
- [x] Add session authentication for `/admin/*` LiveView routes
- [x] Mount `AgentDbWeb.Router` in `AgentDb.WebEndpoint`

## Controllers

- [x] Create `lib/agent_db_web/controllers/health_controller.ex` — GET `/health`
- [x] Create `lib/agent_db_web/controllers/document_controller.ex` — CRUD for documents
- [x] Create `lib/agent_db_web/controllers/search_controller.ex` — search endpoints
- [x] Create `lib/agent_db_web/controllers/session_controller.ex` — session endpoints
- [x] Create `lib/agent_db_web/controllers/model_controller.ex` — model status
- [x] Add controller tests for each (happy path + error cases)

## Shared Context Modules

- [x] Create `lib/agent_db_web/context.ex` — shared functions for controllers/LiveViews
- [x] Document context functions: `list_documents/1`, `get_document/1`, `create_document/2`, `update_document/2`, `delete_document/1`, `search_documents/2`, `list_sessions/1`, `get_session/1`, `model_status/0`, `health_check/0`

## LiveView — Admin Dashboard

- [x] Create `lib/agent_db_web/live/admin_live.ex` — main dashboard LiveView
- [x] Create `lib/agent_db_web/live/admin_live/index.html.heex` — dashboard template with tabs
- [x] Create `lib/agent_db_web/live/document_live.ex` — document tree component
- [x] Create `lib/agent_db_web/live/session_live.ex` — session list component
- [x] Create `lib/agent_db_web/live/model_live.ex` — model status component
- [x] Create `lib/agent_db_web/live/job_live.ex` — job queue component
- [x] Add PubSub subscription for real-time updates (`AgentDb.PubSub`)
- [x] Add LiveView tests for dashboard mount and event handling

## LiveView — Document Editor

- [x] Create `lib/agent_db_web/live/document_editor_live.ex` — editor LiveView
- [x] Create `lib/agent_db_web/live/document_editor_live/edit.html.heex` — editor template
- [x] Implement auto-save to localStorage
- [x] Implement "Publish" action calling context function
- [x] Show abstract/overview panels (read-only, auto-refresh)
- [x] Add syntax highlighting (Prism.js or similar via assets)

## Authentication

- [x] Create `lib/agent_db_web/plugs/auth_plug.ex` — Bearer token verification
- [x] Create `lib/agent_db_web/plugs/session_auth.ex` — LiveView session auth
- [x] Integrate plugs into router pipelines
- [x] Add config for `http_auth_tokens` (reuse existing config)

## Application Integration

- [x] Update `AgentDb.Application` to ensure router starts with endpoint
- [x] Verify `AgentDb.WebEndpoint` includes router and LiveView socket
- [x] Add `Phoenix.PubSub` to supervision tree (if not present)
- [x] Verify all children start in correct order

## Testing

- [x] Controller tests: `test/agent_db_web/controllers/*_test.exs`
- [x] LiveView tests: `test/agent_db_web/live/*_test.exs`
- [x] Integration tests: `test/integration/web_test.exs` — full HTTP flow
- [x] Run `mix test` — all pass

## Documentation

- [x] Add README section for web UI (start, access admin, API examples)
- [x] Document environment variables for HTTP/LiveView config