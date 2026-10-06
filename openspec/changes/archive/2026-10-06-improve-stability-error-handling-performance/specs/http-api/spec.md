# Spec Delta — http-api

## ADDED Requirements

### Requirement: Storage and worker failures never terminate the transport
The system SHALL translate storage-busy, storage-error, worker-crash, and inference-failure outcomes into error envelopes with a bounded `code` and SHALL NOT terminate the caller process, channel, or session. A caller-fixable request (bad mode, URI, scope, limit, query) SHALL always receive a 4xx-class response with its reason and SHALL NEVER receive a 500. A failure the caller cannot fix (unavailable model, failed leg, storage error) SHALL receive a 5xx-class or error-envelope response carrying the classified reason, with a still-loading model staying distinguishable as retryable.

#### Scenario: Contended write over WebSocket stays usable
- **WHEN** a `v1.write` encounters database contention or a worker failure
- **THEN** the client receives an error envelope with a bounded `code`
- **AND** the same connection serves a subsequent valid call

#### Scenario: Same failure, same code on every transport
- **WHEN** the same invalid request is sent over REST, WebSocket, MCP, and CLI
- **THEN** each transport reports the same machine-readable reason for it
- **AND** no transport emits a raw tuple, atom-tagged, or otherwise non-JSON-encodable term

#### Scenario: Invalid startup configuration fails with a reason
- **WHEN** the store is configured with an invalid value such as a non-positive worker count
- **THEN** startup reports a validation error naming the setting
- **AND** it does not boot with a silently substituted default nor crash with an unclassified raise
