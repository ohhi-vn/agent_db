## Purpose

Exposes all context store operations (documents, search, sessions, vector search, summarization status) via a WebSocket API using PhoenixGenApi, enabling remote AI agents and clients to interact with the store.

## ADDED Requirements

### Requirement: WebSocket gateway for all store operations
The system SHALL expose a PhoenixGenApi WebSocket gateway that accepts connections and routes function calls to the underlying store. All existing `AgentDb` operations (write, read, abstract, overview, list, tree, rm, search, sessions, commit) SHALL be available as remote calls.

#### Scenario: Remote write and read
- **WHEN** a client connects via WebSocket and calls `write(uri, content)`
- **THEN** the document is persisted in the store
- **AND** a subsequent `read(uri)` call returns the content

#### Scenario: Remote search (keyword, vector, hybrid)
- **WHEN** a client calls `search(term, mode: :vector, top_k: 10)`
- **THEN** vector search executes and returns ranked results with scores
- **WHEN** a client calls `search(term, mode: :hybrid)`
- **THEN** hybrid results are returned

### Requirement: Session management over WebSocket
Clients SHALL be able to create sessions, append messages, retrieve messages, and commit sessions to the context tree via the WebSocket API.

#### Scenario: Remote session workflow
- **WHEN** client calls `create_session()` → returns session_id
- **AND** client calls `append_message(session_id, :user, "hello")`
- **AND** client calls `get_session(session_id)` → returns messages
- **AND** client calls `commit_session(session_id, destination_uri)`
- **THEN** all operations execute against the shared store

### Requirement: Model status and health endpoints
The API SHALL expose endpoints for checking embedding model and LLM status: loaded/not loaded, memory usage, last inference latency, queue depth for background jobs.

#### Scenario: Model status query
- **WHEN** client calls `model_status()`
- **THEN** returns `{embedding: %{loaded: true, dim: 384}, llm: %{loaded: true, params: "3.8B"}, queue: %{pending: 3}}`

### Requirement: Authentication and authorization (optional, configurable)
The WebSocket gateway SHALL support optional token-based authentication. When enabled, all calls require a valid Bearer token. Authorization SHALL be per-operation (read vs write vs admin) with configurable policies.

#### Scenario: Authenticated access
- **WHEN** auth is enabled and client connects with valid token
- **THEN** all permitted operations succeed

#### Scenario: Unauthenticated rejected
- **WHEN** auth is enabled and client connects without token
- **THEN** connection is rejected or operations return `:unauthorized`

### Requirement: Real-time subscriptions (optional)
Clients SHALL be able to subscribe to document changes (write, rm) and session commits via Phoenix Channels, receiving real-time notifications.

#### Scenario: Subscribe to document changes
- **WHEN** client subscribes to `viking://resources/project/*`
- **AND** another client writes to `viking://resources/project/readme.md`
- **THEN** first client receives notification with changed URI

### Requirement: API versioning and backward compatibility
The WebSocket API SHALL use versioned function names (e.g., `v1.write`, `v1.search`). Breaking changes SHALL introduce a new version while maintaining old versions for a deprecation period.

#### Scenario: Versioned calls
- **WHEN** client calls `v1.write(uri, content)`
- **THEN** operation executes against v1 contract
- **WHEN** v2 is introduced, v1 remains functional