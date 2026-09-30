# Spec Delta

## ADDED Requirements

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
