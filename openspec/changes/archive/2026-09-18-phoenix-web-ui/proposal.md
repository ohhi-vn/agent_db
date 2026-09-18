## Why

The project already has a Phoenix WebSocket endpoint (`AgentDb.WebEndpoint`) and channel (`AgentDb.WebChannel`) for the WebSocket API. However, there's no:
- Traditional HTTP REST API via Phoenix Controllers
- Phoenix LiveView for administrative UI (document manager, session viewer, model status dashboard)
- Phoenix Router with proper plug pipelines for HTTP

This change adds a complete Phoenix web layer complementing the existing WebSocket API.

## What Changes

- **New**: Phoenix Router with `:browser` and `:api` pipelines
- **New**: REST Controllers for documents (CRUD), search, sessions, model status, health
- **New**: LiveView for admin dashboard (document tree, search, sessions, model status, job queue)
- **New**: LiveView for document editor/viewer with real-time updates
- **New**: Shared context modules (`AgentDbWeb.DocumentController`, `AgentDbWeb.SearchController`, etc.) for controller/LiveView reuse
- **New**: Authentication plug for HTTP endpoints (Bearer token, session-based for LiveView)
- **New**: Static asset serving (esbuild/tailwind) for LiveView
- **Modified**: `AgentDb.Application` to start router/endpoint with proper supervision
- **Modified**: `AgentDb.WebEndpoint` to include router and LiveView config

## Capabilities

### New Capabilities

- `phoenix-router`: HTTP routing with browser/api pipelines, CORS, authentication
- `rest-api`: Traditional REST endpoints for all store operations
- `liveview-admin`: LiveView dashboard for documents, sessions, models, jobs
- `liveview-editor`: LiveView document editor with real-time collaboration hints

### Modified Capabilities

- `http-api`: Extend to include REST endpoints alongside WebSocket
- `context-store`: No functional changes, but gains HTTP-accessible UI

## Impact

| Area | Change |
|------|--------|
| `AgentDb.Application` | Add `AgentDbWeb.Router` to supervision tree |
| `AgentDb.WebEndpoint` | Add router, LiveView socket, static assets config |
| Dependencies | + `phoenix_live_view`, `phoenix_live_dashboard`, `tailwind`, `esbuild` |
| Database | No schema changes |
| Config | HTTP port, auth tokens, LiveView signing salt |
| Tests | Controller tests, LiveView tests, integration tests |