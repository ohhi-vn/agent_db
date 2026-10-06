# Spec Delta — runtime-observability

## ADDED Requirements

### Requirement: Bounded redacted error taxonomy
The system SHALL classify every operational failure with a bounded machine-readable code from a documented taxonomy shared by telemetry, logs, and transport responses. A binary error detail SHALL NOT pass through verbatim into logs, metrics, or responses; it SHALL be mapped to a bounded code with redacted detail. Metric and log dimensions SHALL be bounded (operation, kind, outcome, code) and SHALL NOT include document URIs, content, prompts, user identifiers, credentials, tokens, or per-row database strings.

#### Scenario: Binary detail is mapped, not echoed
- **WHEN** a storage, inference, or background-job operation fails with a free-form binary message
- **THEN** telemetry and logs record a bounded code for the failure
- **AND** the raw message content is not emitted as the code or message body

#### Scenario: Unknown job kinds do not create unbounded labels
- **WHEN** background jobs carry unexpected kind values
- **THEN** measurements record a bounded `unknown` bucket with the classified reason
- **AND** no per-value metric series is created

#### Scenario: Sensitive values never appear in diagnostics
- **WHEN** an operation fails for a URI holding sensitive content or a configured URL holds credentials
- **THEN** the structured log and error code name the reason without the URI, content, prompts, or credentials

### Requirement: Expected domain outcomes stay non-fatal
The system SHALL preserve existing `{:ok}/{:error}` contracts for expected domain outcomes (`:not_found`, `:model_loading`, validation errors) and SHALL NOT convert them into process failures for logging or measurement. A malformed trace context SHALL start a new trace and SHALL NOT fail the operation.

#### Scenario: Expected error keeps its shape
- **WHEN** an operation returns `:not_found` or `:model_loading`
- **THEN** the caller receives the existing error shape unchanged
- **AND** the caller and connection are not terminated
