# Spec Delta

## MODIFIED Requirements

### Requirement: Operational failures have structured, redacted logs
Unexpected operational failures, background-job state transitions, and other operational events SHALL be logged as structured events carrying the component, operation or job kind, outcome, classified error, and available trace correlation identifiers. Logs SHALL NOT contain document content, model prompts, authentication tokens, credentials, or unredacted secret-bearing URLs. Expected domain outcomes SHALL retain their existing error behavior and SHALL NOT be converted into process failures for logging.

#### Scenario: Operational failure is traceable without exposing input
- **WHEN** a storage, inference, transport, or background-job operation fails
- **THEN** a structured log identifies the failed operation and classified reason and includes available trace identifiers
- **AND** the log omits the document content, prompt, and credentials involved

#### Scenario: A configured secret-bearing URL is redacted
- **WHEN** a model download uses a configured URL containing credentials or secret query parameters
- **THEN** download success and failure logs do not expose those credentials or parameters

#### Scenario: Expected domain errors preserve their contract
- **WHEN** an operation returns an expected error such as `:not_found` or `:model_loading`
- **THEN** the caller receives the existing error shape
- **AND** observability does not terminate the caller or connection

#### Scenario: Operational logs carry trace and job correlation
- **WHEN** an operation that has a trace context logs an event
- **THEN** the log carries that operation's trace identifier
- **AND** a durable job's log carries the job identifier together with the trace identifier the job was enqueued under

#### Scenario: Operational logs use bounded structured fields
- **WHEN** any operational event is logged — a failure, a state transition, or a fallback
- **THEN** the log carries bounded structured fields (component, operation or kind, outcome, classified reason)
- **AND** it does not emit a free-form interpolated failure term
