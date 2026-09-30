# Spec Delta

## ADDED Requirements

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
