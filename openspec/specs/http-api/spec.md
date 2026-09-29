# http-api Specification

## Purpose
Exposes all context store operations (documents, search, sessions, vector search, summarization status) via a WebSocket API using PhoenixGenApi, enabling remote AI agents and clients to interact with the store.

## Requirements

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
### Requirement: Session management over WebSocket
Clients SHALL be able to create sessions, append messages, retrieve messages, and commit sessions to the context tree via the WebSocket API.

#### Scenario: Remote session workflow
- **WHEN** client calls `create_session()` → returns session_id
- **AND** client calls `append_message(session_id, :user, "hello")`
- **AND** client calls `get_session(session_id)` → returns messages
- **AND** client calls `commit_session(session_id, destination_uri)`
- **THEN** all operations execute against the shared store

### Requirement: Model status and health endpoints
The API SHALL expose endpoints for checking embedding model and LLM status: loaded/not loaded, memory usage, last inference latency, queue depth for background jobs. Model status SHALL remain answerable while a model is being downloaded or loaded, and SHALL report that a load is in progress rather than appearing simply unloaded. The parameter size reported for the summarization model SHALL reflect the configured model rather than a value fixed in the source, so that status output does not describe a model the store is not using.

#### Scenario: Model status query
- **WHEN** client calls `model_status()`
- **THEN** returns a map with `embedding`, `llm`, and `queue` entries
- **AND** the `embedding` entry reports whether the embedding model is loaded and its dimensionality
- **AND** the `llm` entry reports whether the summarization model is loaded and its parameter size

#### Scenario: Model status answers while a model is loading
- **WHEN** a model is being downloaded or loaded
- **THEN** `model_status()` returns a response rather than failing or hanging
- **AND** the response indicates that a load is in progress

#### Scenario: Reported model size follows configuration
- **WHEN** the configured summarization model differs from a previously reported one
- **THEN** `model_status()` reports the size of the currently configured model
- **AND** the reported size is not a fixed value that ignores the configuration

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

### Requirement: HTTP listener lifecycle and binding
When HTTP is enabled the store SHALL open a listener on the configured port and serve requests on it. Enabling HTTP SHALL be observable as a reachable listening socket, not merely as a started endpoint process; a started endpoint that accepts no connection does not satisfy this requirement. When HTTP is disabled the store SHALL leave no listener open.

The listener SHALL bind the loopback interface by default, and the bind interface SHALL be configurable so that a deployment on a private network can select a specific address. The port SHALL be taken from a single configuration source, so that one configured value determines the port served and no second, competing port setting can silently disagree with it.

#### Scenario: Enabled HTTP serves requests
- **WHEN** the store starts with HTTP enabled and a port configured
- **THEN** a TCP listener accepts a request on that port
- **AND** the request is answered by the store rather than refused

#### Scenario: Disabled HTTP opens no listener
- **WHEN** the store starts with HTTP disabled
- **THEN** no TCP listener is open on the configured port
- **AND** a request to that port is refused

#### Scenario: The listener binds loopback by default
- **WHEN** the store starts with HTTP enabled and no bind interface configured
- **THEN** the listener is reachable on the loopback interface
- **AND** the listener is not bound to a non-loopback interface

#### Scenario: The bind interface is configurable
- **WHEN** the store starts with HTTP enabled and a bind interface configured
- **THEN** the listener is reachable on the configured interface
- **AND** the default loopback binding does not apply

#### Scenario: One configured port determines what is served
- **WHEN** the store starts with HTTP enabled and a port configured
- **THEN** the listener is opened on exactly that port
- **AND** no other port value overrides it

#### Scenario: Serving is observable rather than assumed
- **WHEN** the store reports that HTTP is enabled
- **THEN** a connection to the configured port succeeds
- **AND** reporting HTTP as enabled while refusing connections is a detectable failure
