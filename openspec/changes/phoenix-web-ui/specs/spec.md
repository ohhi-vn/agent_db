# phoenix-web-ui Specification

## Purpose
Adds a complete Phoenix web layer (Router, REST Controllers, LiveView) for administrative UI and traditional HTTP API, complementing the existing WebSocket API.

## Requirements

### Requirement: Phoenix Router with plug pipelines
The system SHALL define a Phoenix Router (`AgentDbWeb.Router`) with two pipelines:
- `:browser` pipeline — accepts HTML, fetches session, puts flash, protects from forgery, puts secure browser headers
- `:api` pipeline — accepts JSON, optional authentication plug

#### Scenario: Browser pipeline serves LiveView
- **WHEN** a request hits `/admin/*` 
- **THEN** the `:browser` pipeline executes and LiveView mounts successfully

#### Scenario: API pipeline serves JSON
- **WHEN** a request hits `/api/v1/*`
- **THEN** the `:api` pipeline executes and returns JSON responses

### Requirement: REST Controllers for document operations
The system SHALL expose REST endpoints for document CRUD:

| Method | Path | Controller Action |
|--------|------|-------------------|
| GET | `/api/v1/documents` | `DocumentController.index` — list with pagination |
| GET | `/api/v1/documents/:id` | `DocumentController.show` — read single |
| POST | `/api/v1/documents` | `DocumentController.create` — write new |
| PUT | `/api/v1/documents/:id` | `DocumentController.update` — update existing |
| DELETE | `/api/v1/documents/:id` | `DocumentController.delete` — remove |

#### Scenario: Create document via REST
- **WHEN** POST `/api/v1/documents` with `{uri, content, opts}`
- **THEN** returns `201` with `{uri, content, abstract, overview}`

#### Scenario: List documents with pagination
- **WHEN** GET `/api/v1/documents?page=2&per_page=20`
- **THEN** returns `200` with `{data: [...], meta: {page, per_page, total}}`

### Requirement: REST Controllers for search
The system SHALL expose search endpoints:

| Method | Path | Controller Action |
|--------|------|-------------------|
| POST | `/api/v1/search` | `SearchController.search` — keyword/vector/hybrid |
| GET | `/api/v1/search/suggest` | `SearchController.suggest` — autocomplete |

#### Scenario: Vector search via REST
- **WHEN** POST `/api/v1/search` with `{term, mode: "vector", top_k: 10}`
- **THEN** returns `200` with `{results: [%{uri, score, content}]}`

### Requirement: REST Controllers for sessions
The system SHALL expose session endpoints:

| Method | Path | Controller Action |
|--------|------|-------------------|
| POST | `/api/v1/sessions` | `SessionController.create` |
| GET | `/api/v1/sessions/:id` | `SessionController.show` |
| POST | `/api/v1/sessions/:id/messages` | `SessionController.append_message` |
| POST | `/api/v1/sessions/:id/commit` | `SessionController.commit` |

### Requirement: Health and model status endpoints
The system SHALL expose:

| Method | Path | Controller Action |
|--------|------|-------------------|
| GET | `/health` | `HealthController.show` — liveness/readiness |
| GET | `/api/v1/models/status` | `ModelController.status` |

#### Scenario: Health check
- **WHEN** GET `/health`
- **THEN** returns `200` with `{status: "ok", checks: %{db: true, models: true}}`

### Requirement: LiveView admin dashboard
The system SHALL provide a LiveView at `/admin` with tabs:
- **Documents** — tree view, search, create/edit/delete
- **Sessions** — list, view messages, commit
- **Models** — embedding/LLM status, memory, queue depth
- **Jobs** — pending/running/completed/failed counts, retry failed

#### Scenario: Admin dashboard loads
- **WHEN** user visits `/admin`
- **THEN** LiveView mounts, shows document tree and stats

#### Scenario: Real-time document updates
- **WHEN** another client writes a document via WebSocket or REST
- **THEN** admin dashboard updates tree in real-time via PubSub

### Requirement: LiveView document editor
The system SHALL provide a LiveView at `/admin/documents/:id/edit`:
- Shows document content with syntax highlighting
- Auto-saves drafts to localStorage
- Shows abstract/overview panels
- "Publish" button writes to store

#### Scenario: Edit document
- **WHEN** user edits content and clicks Publish
- **THEN** document updates, abstract/overview regenerate, dashboard reflects change

### Requirement: Authentication for HTTP
The system SHALL support:
- **API**: Bearer token authentication (configurable tokens)
- **LiveView**: Session-based auth (optional, can reuse API tokens via header)

#### Scenario: Authenticated API request
- **WHEN** request includes `Authorization: Bearer <valid-token>`
- **THEN** request proceeds

#### Scenario: Unauthenticated API request
- **WHEN** auth enabled and no token provided
- **THEN** returns `401 Unauthorized`

### Requirement: Static assets and LiveView setup
The system SHALL configure:
- esbuild for JS bundling
- Tailwind CSS for styling
- LiveView JS client
- Phoenix.LiveDashboard at `/dev/dashboard` (dev only)

#### Scenario: Assets compile
- **WHEN** `mix assets.setup && mix assets.build`
- **THEN** `priv/static/assets/` contains `app.js`, `app.css`

### Requirement: CORS support
The API pipeline SHALL include CORS plug allowing configured origins.

#### Scenario: Cross-origin request
- **WHEN** request from allowed origin with `Origin` header
- **THEN** response includes `Access-Control-Allow-Origin`

## Non-Requirements
- No GraphQL API
- No OpenAPI/Swagger generation (can be added later)
- No multi-tenancy in this change
- No WebSocket fallback for LiveView (uses standard LiveView websocket)