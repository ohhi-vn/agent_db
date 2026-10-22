# runtime-observability Specification

## Purpose
Provides operators and host applications with safe runtime diagnostics, repeatable performance measurements, and correlated traces across AgentDb operations and asynchronous work.

## Requirements

### Requirement: Runtime operations emit measurable outcomes
The system SHALL emit runtime measurements for public store operations and durable background jobs, including operation or job kind, duration, and outcome. Queue wait and execution time SHALL be distinguishable for background jobs. Measurement dimensions SHALL be bounded and SHALL NOT include document URIs, content, prompts, user identifiers, credentials, or tokens. A background job's outcome SHALL distinguish a completed job from a deferred one, a failed one, and a discarded one; the set of outcome values SHALL be a fixed, documented set so that a consumer can count each outcome separately and a job that fails is never counted as a job that succeeded.

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

#### Scenario: A failed job is not counted as a success
- **WHEN** a durable job exhausts its attempts and is marked failed
- **THEN** the measurement for that job carries the failed outcome
- **AND** the job is not counted under the successful outcome

#### Scenario: A deferred job is not counted as a failure
- **WHEN** a durable job is rescheduled because its model is still loading
- **THEN** the measurement for that job carries the deferred outcome
- **AND** the job is not counted under the failed outcome

#### Scenario: A discarded job is distinguishable
- **WHEN** a durable job's result is discarded because the document it targeted no longer exists
- **THEN** the measurement for that job carries the discarded outcome
- **AND** it is distinguishable from both the successful and failed outcomes

#### Scenario: The outcome set is fixed
- **WHEN** measurements are emitted for many different kinds of work
- **THEN** every outcome value is one of the documented outcome values
- **AND** no new outcome value is introduced by a per-call detail

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
Unexpected operational failures, background-job state transitions, and other operational events SHALL be logged as structured events carrying the component, operation or job kind, outcome, classified error, and available trace correlation identifiers. Logs SHALL NOT contain document content, model prompts, authentication tokens, credentials, or unredacted secret-bearing URLs. Expected domain outcomes SHALL retain their existing error behavior and SHALL NOT be converted into process failures for logging. The classified error carried by a log SHALL be the same code carried by the corresponding measurement and the corresponding transport error response, so the three can be correlated on the code alone.

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

#### Scenario: A log, a measurement, and a response agree on the code
- **WHEN** one failure produces a log entry, a measurement, and a transport error response
- **THEN** all three carry the same classified code

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

### Requirement: Bounded redacted error taxonomy
The system SHALL classify every operational failure with a bounded machine-readable code from a documented taxonomy shared by telemetry, logs, and transport responses. A binary error detail SHALL NOT pass through verbatim into logs, metrics, or responses; it SHALL be mapped to a bounded code with redacted detail. Metric and log dimensions SHALL be bounded (operation, kind, outcome, code) and SHALL NOT include document URIs, content, prompts, user identifiers, credentials, tokens, or per-row database strings. A measurement describing a failure SHALL carry the classified code for that failure, and that code SHALL be the same code the corresponding transport error response reports, so a consumer can join a metric series to a transport response on the code alone.

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

#### Scenario: A failure measurement carries its classified code
- **WHEN** an operation fails with a classified reason
- **THEN** the measurement carries that reason as its code
- **AND** the code is the same one the corresponding transport error response reports

#### Scenario: The code dimension is populated
- **WHEN** a measurement describing a failure is emitted
- **THEN** it carries a code drawn from the documented taxonomy
- **AND** the code is not a generic placeholder for every failure

### Requirement: Expected domain outcomes stay non-fatal
The system SHALL preserve existing `{:ok}/{:error}` contracts for expected domain outcomes (`:not_found`, `:model_loading`, validation errors) and SHALL NOT convert them into process failures for logging or measurement. A malformed trace context SHALL start a new trace and SHALL NOT fail the operation.

#### Scenario: Expected error keeps its shape
- **WHEN** an operation returns `:not_found` or `:model_loading`
- **THEN** the caller receives the existing error shape unchanged
- **AND** the caller and connection are not terminated

### Requirement: Operation statistics are retained for reporting
The system SHALL retain, in memory and in bounded space, per-operation statistics sufficient to answer questions about how the store has been behaving: how many times each operation succeeded and failed, the latency distribution of each operation, and the resulting error rate. Latency SHALL be retained for successful operations as well as for failures. The retained statistics SHALL be reportable through the store's public surface.

#### Scenario: Per-operation counts are reportable
- **WHEN** operations have succeeded and failed
- **THEN** the store reports the success and failure count for each operation

#### Scenario: Latency percentiles are reportable
- **WHEN** an operation has run repeatedly
- **THEN** the store reports its median, 95th, and 99th percentile latency

#### Scenario: The error rate is reportable
- **WHEN** an operation has both succeeded and failed
- **THEN** the store reports the proportion of its calls that failed

#### Scenario: Latency is retained for successful operations too
- **WHEN** an operation succeeds
- **THEN** its latency is retained for reporting
- **AND** the retained statistics are not limited to failures

### Requirement: Retained statistics stay bounded
The statistics retained for reporting SHALL be bounded in both the number of tracked operations and the size of each operation's retained history, so that a long-running store does not grow its diagnostic footprint without limit. When a bound is reached, the oldest retained entries SHALL be dropped rather than accumulated.

#### Scenario: The retained statistics stay bounded
- **WHEN** a large number of distinct operations and results have been recorded
- **THEN** the retained statistics remain within a fixed size bound
- **AND** the oldest retained entries are dropped rather than accumulating
