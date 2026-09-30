# Spec Delta

## ADDED Requirements

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
