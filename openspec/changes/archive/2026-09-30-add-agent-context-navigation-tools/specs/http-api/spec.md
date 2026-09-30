# Spec Delta

## ADDED Requirements

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
