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
Clients SHALL be able to subscribe to document changes (write, rm, skill replacement) and session commits via Phoenix Channels, receiving real-time versioned notifications. Each notification SHALL carry the changed URI, a change kind of `written | removed | replaced | committed`, and a monotonic version, and SHALL NOT carry document content. Scope membership SHALL be exact-URI-or-descendant. A subscription to a syntactically valid but missing URI SHALL succeed and fire on creation; an invalid URI SHALL return `{:error, :invalid_uri}` without terminating the channel.

#### Scenario: Subscribe to document changes
- **WHEN** client subscribes to `viking://resources/project/*`
- **AND** another client writes to `viking://resources/project/readme.md`
- **THEN** first client receives notification with changed URI

#### Scenario: Versioned removal notification
- **WHEN** a client is subscribed to `viking://resources/project` and that subtree is removed
- **THEN** the client receives a `removed` notification with the URI and its version
- **AND** the channel remains usable for further events

#### Scenario: Invalid subscription leaves the channel usable
- **WHEN** a client sends `v1.subscribe` with an invalid URI
- **THEN** the client receives an `{:error, :invalid_uri}` response
- **AND** a subsequent valid subscription on the same connection succeeds

### Requirement: Retrieval progress streaming
The versioned WebSocket API SHALL expose `v1.subscribe` and `v1.unsubscribe` for context scopes plus streaming progress events for retrieval: `retrieval started`, `retrieval progress`, `resource found`, `memory found`, `skill loaded`, and `context assembled`. Progress events SHALL be informational only and SHALL NOT change the final `search` result contract. A client that cannot be served (unavailable provider) SHALL receive an error response without terminating the connection, and a deferred call SHALL remain distinguishable as `:model_loading`.

#### Scenario: Streamed retrieval for debugging
- **WHEN** a client subscribes to progress and calls `v1.search` with mode hybrid
- **THEN** the client receives ordered progress events ending in a final result payload matching the existing `v1.search` envelope

#### Scenario: Progress failure does not break the call
- **WHEN** a progress subscription drops mid-retrieval
- **THEN** the underlying `search` still returns its final result to the caller

### Requirement: API versioning and backward compatibility
The WebSocket API SHALL use versioned function names (e.g., `v1.write`, `v1.search`). Breaking changes SHALL introduce a new version while maintaining old versions for a deprecation period.

#### Scenario: Versioned calls
- **WHEN** client calls `v1.write(uri, content)`
- **THEN** operation executes against v1 contract
- **WHEN** v2 is introduced, v1 remains functional

### Requirement: HTTP listener lifecycle and binding
When HTTP is enabled the store SHALL open a listener on the configured port and serve requests on it. Enabling HTTP SHALL be observable as a reachable listening socket, not merely as a started endpoint process; a started endpoint that accepts no connection does not satisfy this requirement. When HTTP is disabled the store SHALL leave no listener open.

The listener SHALL bind the loopback interface by default, and the bind interface SHALL be configurable so that a deployment on a private network can select a specific address. The port SHALL be taken from a single configuration source (`AGENT_DB_HTTP_PORT` with default `6060`), so that one configured value determines the port served and no second, competing port setting can silently disagree with it. When `AGENT_DB_HTTP_PORT` is unset the listener SHALL open on `6060`.

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

#### Scenario: Default port is 6060 when unconfigured
- **WHEN** the store starts with HTTP enabled and `AGENT_DB_HTTP_PORT` unset
- **THEN** a TCP listener accepts a request on `6060`
- **AND** the generated endpoint URL uses port `6060`

### Requirement: HTTP and WebSocket operations accept trace context
The HTTP and WebSocket APIs SHALL accept valid W3C trace context at their request or operation boundary and propagate it to the corresponding store operation. An HTTP request SHALL use its `traceparent` header; a WebSocket operation MAY supply `traceparent` metadata with the event. Missing or malformed trace context SHALL result in a new trace and SHALL NOT reject, authorize, or otherwise change the operation. Trace metadata SHALL NOT change existing request or response payload shapes.

#### Scenario: HTTP request continues a caller trace
- **WHEN** an HTTP API request carries a valid W3C `traceparent` header
- **THEN** the operation continues that trace through its store work
- **AND** the existing HTTP status and response body contract is preserved

#### Scenario: WebSocket operation continues a caller trace
- **WHEN** a WebSocket event carries valid W3C `traceparent` metadata
- **THEN** the event's store operation continues that trace
- **AND** the existing event result contract is preserved

#### Scenario: Missing or malformed context starts a trace without rejecting the call
- **WHEN** an HTTP request or WebSocket event has no trace context or has malformed trace context
- **THEN** the operation starts a new trace
- **AND** authentication, authorization, operation results, and connection usability follow their existing contracts
### Requirement: Remote path discovery and content inspection
The versioned WebSocket API SHALL expose `v1.find` and `v1.grep`, each accepting a required `term` and optional `opts.scope` and `opts.limit`, and SHALL return their results in the existing success response envelope. The events SHALL preserve the in-process operation's validation, scoping, literal matching, ordering, and result limits. Invalid requests SHALL receive the existing error response shape without terminating the caller or channel connection. Existing `v1` events and authentication behavior SHALL remain unchanged.

#### Scenario: A remote agent discovers paths progressively
- **WHEN** a client sends `v1.find` with a term and subtree scope
- **THEN** the response contains the matching URI, name, and node kind entries
- **AND** the client can use existing `v1.list` and `v1.read` events to continue navigating

#### Scenario: A remote agent retrieves matching source excerpts
- **WHEN** a client sends `v1.grep` with a term and optional subtree scope
- **THEN** the response contains matching document URIs, one-based line numbers, and bounded excerpts
- **AND** the response is limited by the operation's effective result limit

#### Scenario: Invalid navigation request leaves the channel usable
- **WHEN** a client sends `v1.find` or `v1.grep` with an invalid term, scope, or limit
- **THEN** the client receives an error using the existing error response envelope
- **AND** a subsequent valid event succeeds on the same connection

### Requirement: MCP Streamable HTTP endpoint on the configured listener
The system SHALL expose `POST /mcp` on the existing HTTP listener as an MCP Streamable HTTP endpoint speaking JSON-RPC with the `legacy` `initialize` handshake. The endpoint SHALL serve on the single configured port, bind loopback by default with a configurable interface, enforce the existing optional Bearer auth contract, and propagate W3C `traceparent` without changing request or response shapes. Error responses SHALL be JSON and SHALL NOT terminate the session. Existing WebSocket `v1.*`, REST, and `/admin` behavior SHALL remain unchanged.

#### Scenario: MCP handshake and tool call over HTTP
- **WHEN** a client posts `initialize` then `tools/call context_search` to `/mcp`
- **THEN** the handshake succeeds and search results return as JSON
- **AND** the listener port is the single configured value

#### Scenario: Bearer enforcement on MCP when enabled
- **WHEN** auth is enabled and a client posts to `/mcp` without a valid token
- **THEN** the request is rejected as unauthorized
- **AND** a request with a valid `Authorization` header succeeds

#### Scenario: Trace context preserved on MCP
- **WHEN** a client posts to `/mcp` with a valid `traceparent` header
- **THEN** the store operation continues that trace
- **AND** the JSON-RPC response shape is unchanged

### Requirement: JSON-safe transport error responses with correct statuses

Every HTTP, WebSocket, MCP, and CLI error response SHALL carry a JSON-safe body and a status that distinguishes caller errors from server failures: an unrecognized search mode, malformed scope, limit, or query SHALL return a 4xx-class response naming the reason, and SHALL NEVER return 500 or terminate the caller or connection. A failure the caller cannot fix (unavailable model, failed leg, storage error) SHALL return a 5xx-class or error-envelope response carrying the classified reason. No raw tuple, atom-tagged, or otherwise non-JSON-encodable term SHALL reach any transport encoder.

#### Scenario: Invalid search mode over REST

- **WHEN** a client calls `POST /api/v1/search` with an unrecognized mode
- **THEN** the response is a 422 with a JSON body naming the invalid mode
- **AND** the connection remains usable for subsequent requests

#### Scenario: Unservable search names its reason

- **WHEN** a client requests a vector search while the embedding model is unavailable
- **THEN** the response carries the classified reason (not a crash, not an empty 500)
- **AND** a request deferred only by a still-loading model stays distinguishable as retryable

#### Scenario: Same failure, same reason on every transport

- **WHEN** the same invalid request is sent over REST, WebSocket, MCP, and CLI
- **THEN** each transport reports the same machine-readable reason for it
