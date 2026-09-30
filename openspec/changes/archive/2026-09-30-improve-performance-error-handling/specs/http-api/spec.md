# Spec Delta

## ADDED Requirements

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
