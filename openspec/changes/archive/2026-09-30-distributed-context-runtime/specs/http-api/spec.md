# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Retrieval progress streaming
The versioned WebSocket API SHALL expose `v1.subscribe` and `v1.unsubscribe` for context scopes plus streaming progress events for retrieval: `retrieval started`, `retrieval progress`, `resource found`, `memory found`, `skill loaded`, and `context assembled`. Progress events SHALL be informational only and SHALL NOT change the final `search` result contract. A client that cannot be served (unavailable provider) SHALL receive an error response without terminating the connection, and a deferred call SHALL remain distinguishable as `:model_loading`.

#### Scenario: Streamed retrieval for debugging
- **WHEN** a client subscribes to progress and calls `v1.search` with mode hybrid
- **THEN** the client receives ordered progress events ending in a final result payload matching the existing `v1.search` envelope

#### Scenario: Progress failure does not break the call
- **WHEN** a progress subscription drops mid-retrieval
- **THEN** the underlying `search` still returns its final result to the caller
