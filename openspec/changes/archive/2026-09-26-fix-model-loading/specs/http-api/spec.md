# Spec Delta

## MODIFIED Requirements

### Requirement: WebSocket gateway for all store operations
The system SHALL expose a PhoenixGenApi WebSocket gateway that accepts connections and routes function calls to the underlying store. All existing `AgentDb` operations (write, read, abstract, overview, list, tree, rm, search, sessions, commit) SHALL be available as remote calls. A call that cannot be served — because a required model is unavailable, or an optional capability is not present — SHALL receive an error response and SHALL NOT terminate the calling process or the connection.

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
