# Spec Delta

## MODIFIED Requirements

### Requirement: WebSocket gateway for all store operations
The system SHALL expose a PhoenixGenApi WebSocket gateway that accepts connections and routes function calls to the underlying store. All existing `AgentDb` operations (write, read, abstract, overview, list, tree, rm, search, sessions, commit) SHALL be available as remote calls. A call that cannot be served — because a required model is unavailable, or an optional capability is not present — SHALL receive an error response and SHALL NOT terminate the calling process or the connection. A call that is deferred only because a model is still loading SHALL be reported to the client in a way the client can distinguish from a call that failed outright, so that a client can retry rather than conclude the capability is unavailable.

#### Scenario: Remote write and read
- **WHEN** a client connects via WebSocket and calls `write(uri, content)`
- **THEN** the document is persisted in the store
- **AND** a subsequent `read(uri)` call returns the content

#### Scenario: Remote search (keyword, vector, hybrid)
- **WHEN** a client calls `search(term, mode: :vector, top_k: 10)`
- **THEN** vector search executes and returns ranked results with scores
- **WHEN** a client calls `search(term, mode: :hybrid)`
- **THEN** hybrid results are returned

#### Scenario: Unservable call returns an error, not a crash
- **WHEN** a client calls an operation that requires an unavailable model
- **THEN** the client receives an error response identifying the reason
- **AND** the connection remains usable for subsequent calls

#### Scenario: A deferred call is distinguishable from a failed one
- **WHEN** a client calls an operation that needs a model which is still loading
- **THEN** the response identifies the call as deferred for a loading model
- **AND** the client can tell it apart from an operation that failed
- **AND** the connection remains usable

### Requirement: Model status and health endpoints
The API SHALL expose endpoints for checking embedding model and LLM status: loaded/not loaded, memory usage, last inference latency, queue depth for background jobs. Model status SHALL remain answerable while a model is being downloaded or loaded, and SHALL report that a load is in progress rather than appearing simply unloaded.

#### Scenario: Model status query
- **WHEN** client calls `model_status()`
- **THEN** returns `{embedding: %{loaded: true, dim: 384}, llm: %{loaded: true, params: "3.8B"}, queue: %{pending: 3}}`

#### Scenario: Model status answers while a model is loading
- **WHEN** a model is being downloaded or loaded
- **THEN** `model_status()` returns a response rather than failing or hanging
- **AND** the response indicates that a load is in progress
