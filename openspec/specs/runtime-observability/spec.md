# runtime-observability Specification

## Purpose
Provides operators and host applications with safe runtime diagnostics, repeatable performance measurements, and correlated traces across AgentDb operations and asynchronous work.

## Requirements

### Requirement: Runtime operations emit measurable outcomes
The system SHALL emit runtime measurements for public store operations and durable background jobs, including operation or job kind, duration, and outcome. Queue wait and execution time SHALL be distinguishable for background jobs. Measurement dimensions SHALL be bounded and SHALL NOT include document URIs, content, prompts, user identifiers, credentials, or tokens.

#### Scenario: Successful and failed operation measurements
- **WHEN** a public operation succeeds or returns an error
- **THEN** a measurement records its operation, elapsed duration, and success or error outcome
- **AND** the measurement does not alter the operation result

#### Scenario: Background job timing and outcome
- **WHEN** a durable job is claimed, deferred, completed, or failed
- **THEN** measurements distinguish queue wait from execution duration and identify the job kind and outcome
- **AND** a deferred job remains distinguishable from a failed job

#### Scenario: Measurements use bounded, private dimensions
- **WHEN** measurements are emitted for different URIs, documents, or users
- **THEN** those values are not used as metric dimensions
- **AND** document content and model prompts are not included

### Requirement: Distributed traces correlate operations and durable work
The system SHALL create a trace for an operation without a valid parent context and SHALL continue a valid incoming trace context across application workflows, storage and inference boundaries, and spawned operation tasks. A durable background job SHALL retain enough trace context to correlate its execution with the operation that enqueued it; worker execution SHALL remain independently finishable after the originating request ends.

#### Scenario: A request continues its incoming trace
- **WHEN** an operation begins with a valid incoming trace context
- **THEN** its application and infrastructure spans belong to that trace
- **AND** structured events for the operation carry matching trace correlation identifiers

#### Scenario: An operation without a parent starts a trace
- **WHEN** an operation begins without an incoming trace context
- **THEN** the system creates a new trace and records its operation spans
- **AND** the operation result and error contract are unchanged

#### Scenario: Durable work is correlated after request completion
- **WHEN** an operation enqueues a durable background job and returns before the job runs
- **THEN** the worker execution can be correlated with the originating trace
- **AND** the worker does not keep the originating request span open
- **AND** trace correlation survives an application restart while the job remains pending

#### Scenario: Invalid trace context does not fail an operation
- **WHEN** an operation receives malformed trace context
- **THEN** the context is rejected and a new trace is started
- **AND** the requested operation continues under its existing success or error contract

### Requirement: Operational failures have structured, redacted logs
Unexpected operational failures and background-job state transitions SHALL be logged as structured events with the component, operation or job kind, outcome, classified error, and available trace correlation identifiers. Logs SHALL NOT contain document content, model prompts, authentication tokens, credentials, or unredacted secret-bearing URLs. Expected domain outcomes SHALL retain their existing error behavior and SHALL NOT be converted into process failures for logging.

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

### Requirement: Retrieval pipeline spans
The system SHALL create one OpenTelemetry span per retrieval stage — intent analysis, resource search, memory search, skill retrieval, embedding, reranking, context assembly, and any LLM call — as children of the originating operation trace, including when stages run in spawned tasks. Each span SHALL carry only bounded attributes (stage name, mode, outcome, duration) and SHALL NOT carry URIs, document content, prompts, user identifiers, credentials, or tokens. A missing or malformed parent context SHALL start a new trace without changing the operation result, and a stage failure SHALL be recorded as a span error without terminating the caller or connection.

#### Scenario: Trace explains an answer
- **WHEN** an agent request runs intent, memory, resource, rerank, assembly, and LLM stages
- **THEN** the trace contains one child span per executed stage with durations that sum to the request wall time within clock precision
- **AND** no span attribute contains document content or prompts

#### Scenario: Invalid parent starts a new trace
- **WHEN** a retrieval begins with malformed trace context
- **THEN** a new trace is started, stages attach to it, and the search result contract is unchanged

### Requirement: Progress measurements without high-cardinality labels
Stage measurements SHALL be emitted via `:telemetry` with queue-wait versus execution split where applicable, using the same bounded-dimension rule as existing operation measurements: stage, mode, and outcome only. URIs, content, prompts, users, and credentials SHALL never be label values.

#### Scenario: Stage timing is measurable without content
- **WHEN** retrieval stages execute for different queries and URIs
- **THEN** measurements distinguish intent, embedding, rerank, and assembly durations by stage and outcome
- **AND** no measurement carries a URI or query string as a dimension

### Requirement: Bounded machine-readable error codes on transport errors

Every error response on every transport SHALL include a `code` drawn from the store's shared error classification (the same taxonomy `Observability` uses for telemetry and logs), so operators can alert on codes without parsing messages. The code set SHALL be bounded and documented; adding a new failure mode SHALL reuse an existing code or extend the taxonomy rather than emitting free-form text as the only signal. Error payloads SHALL NOT contain document URIs, content, prompts, user identifiers, credentials, tokens, or unredacted secret-bearing URLs.

#### Scenario: Error code present and bounded

- **WHEN** any store operation fails over any transport
- **THEN** the error response includes a `code` from the documented taxonomy
- **AND** the code matches the classification recorded in telemetry for the same failure

#### Scenario: Error payloads carry no sensitive data

- **WHEN** an operation fails for a URI holding sensitive content
- **THEN** the error response names the reason without echoing the URI, content, prompts, users, or credentials
