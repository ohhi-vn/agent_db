# Spec Delta

## Purpose

Documents the system architecture including component boundaries, data flows, deployment topology, and the relationship between the context store, memory system, inference pipeline, background job queue, and transport layers so operators and developers can reason about system behavior, capacity, and failure modes.

## ADDED Requirements

### Requirement: Architecture guide explains component boundaries and data flows
The system SHALL provide `guides/ARCHITECTURE.md` that describes the major components (context store, memory system, inference pipeline, job queue, HTTP/MCP/WebSocket transports), their responsibilities, and how data flows between them including write path, read path, search path, and background job processing.

#### Scenario: Reader identifies component responsibilities
- **WHEN** an operator reads `guides/ARCHITECTURE.md`
- **THEN** they can name each component and its primary responsibility without reading source code

#### Scenario: Reader traces a write through the system
- **WHEN** an operator follows the write-path diagram in `guides/ARCHITECTURE.md`
- **THEN** they can explain the sequence from API call to SQLite persistence, cache update, job enqueue, and async embedding/summarization completion

#### Scenario: Reader understands transport layer separation
- **WHEN** an operator reads the transport section
- **THEN** they can distinguish HTTP REST, MCP Streamable HTTP, and WebSocket `v1.*` event formats and know which use cases each serves

### Requirement: Architecture guide documents deployment topology and scaling limits
The system SHALL document the single-node deployment model, the role of BEAM distribution (explicitly deferred), SQLite as the source of truth with ETS as disposable cache, and the concurrency limits for inference, job workers, and HTTP connections.

#### Scenario: Operator plans capacity
- **WHEN** an operator reads the deployment section
- **THEN** they know the single-node model, that BEAM clustering is not used, and which knobs control inference concurrency (`inference_concurrency`), job parallelism (`job_workers`), and HTTP listener bind address

#### Scenario: Reader understands cache vs durability guarantees
- **WHEN** an operator reads the storage section
- **THEN** they know SQLite is the source of truth, ETS caches are rebuilt lazily on restart, and writes are acknowledged only after SQLite persistence and job enqueue

### Requirement: Architecture guide links to relevant specs and code entry points
The system SHALL include cross-references to the capability specs (`context-store`, `memory`, `vector-search`, `inference-providers`, `runtime-observability`, `http-api`, `agent-tooling`, `admin-dashboard`) and the primary Elixir modules that implement each component so readers can navigate from guide to spec to implementation.

#### Scenario: Reader navigates from guide to spec to code
- **WHEN** an operator clicks a spec reference in `guides/ARCHITECTURE.md`
- **THEN** they land on the corresponding spec in `openspec/specs/`
- **AND** code entry points (e.g., `AgentDb.write/3`, `AgentDb.JobQueue`, `AgentDb.Inference`) are named so they can be found in the codebase