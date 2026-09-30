# Spec Delta

## ADDED Requirements

### Requirement: Bounded machine-readable error codes on transport errors

Every error response on every transport SHALL include a `code` drawn from the store's shared error classification (the same taxonomy `Observability` uses for telemetry and logs), so operators can alert on codes without parsing messages. The code set SHALL be bounded and documented; adding a new failure mode SHALL reuse an existing code or extend the taxonomy rather than emitting free-form text as the only signal. Error payloads SHALL NOT contain document URIs, content, prompts, user identifiers, credentials, tokens, or unredacted secret-bearing URLs.

#### Scenario: Error code present and bounded

- **WHEN** any store operation fails over any transport
- **THEN** the error response includes a `code` from the documented taxonomy
- **AND** the code matches the classification recorded in telemetry for the same failure

#### Scenario: Error payloads carry no sensitive data

- **WHEN** an operation fails for a URI holding sensitive content
- **THEN** the error response names the reason without echoing the URI, content, prompts, users, or credentials
