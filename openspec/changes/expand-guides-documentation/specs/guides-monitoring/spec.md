# Spec Delta

## Purpose

Provides operators with a production monitoring and observability guide connecting the runtime-observability and admin-dashboard specs to operational practice, covering the /admin console, telemetry events, structured logs, health checks, error taxonomy, and alerting recommendations.

## ADDED Requirements

### Requirement: Monitoring guide documents the /admin console as the primary operational interface
The system SHALL provide `guides/MONITORING.md` that explains how to use the `/admin` console for real-time store inspection including storage footprint, cache and BEAM memory, model status, queue depth and failed jobs, index coverage, and recent errors.

#### Scenario: Operator checks store health at a glance
- **WHEN** an operator opens `/admin` as described in `guides/MONITORING.md`
- **THEN** they can verify database connectivity, model readiness, queue health, and index coverage from a single page

#### Scenario: Operator diagnoses a backlog
- **WHEN** an operator sees elevated pending job counts in the console
- **THEN** the guide explains how to inspect failed jobs, read classified failure reasons, and correlate with telemetry

#### Scenario: Operator distinguishes cache growth from content growth
- **WHEN** an operator sees rising BEAM memory
- **THEN** the guide explains how to read cache table entry counts and memory from the console to isolate the cause

### Requirement: Monitoring guide documents telemetry events and structured logs for external observability stacks
The system SHALL document the `:telemetry` events emitted by the store (`agent_db.operation.stop`, `agent_db.job.stop`, `agent_db.model.stop`, retrieval pipeline stages), their attributes (operation, kind, outcome, duration, stage, mode), and the bounded-dimension rule (no URIs, content, prompts, users, credentials as label values). It SHALL document the structured log format, the shared error taxonomy, and how to correlate logs with traces using `traceparent`.

#### Scenario: Operator configures Prometheus/Grafana from telemetry
- **WHEN** an operator reads the telemetry section
- **THEN** they know which events to subscribe to, the attribute names for dashboards, and that cardinality is bounded by design

#### Scenario: Operator sets up log aggregation with redacted errors
- **WHEN** an operator configures log shipping
- **THEN** the guide explains the structured log fields, the error code taxonomy, and that secrets are never logged (validated by the runtime-observability spec)

#### Scenario: Operator correlates a request across transports
- **WHEN** an operator traces a request from MCP through background job execution
- **THEN** the guide explains how `traceparent` propagates and where to find correlation IDs in logs and telemetry

### Requirement: Monitoring guide documents health checks and alerting recommendations
The system SHALL document the `AgentDb.health_check/0`, `AgentDb.model_status/0`, `AgentDb.queue_stats/0` functions and the `mix agent_db.doctor` CLI, their output shapes, and recommended alert thresholds (e.g., model load state != `:ready`, pending jobs > threshold, oldest pending age > threshold, failed jobs > 0, DB check false).

#### Scenario: Operator writes a health check for orchestration
- **WHEN** an operator implements a liveness/readiness probe
- **THEN** the guide shows the exact command and JSON shape to parse, and which fields indicate ready vs degraded

#### Scenario: Operator sets up alerts for queue backpressure
- **WHEN** an operator configures alerting
- **THEN** the guide recommends specific thresholds for pending job count, oldest pending age, and failed job count based on the queue stats output

### Requirement: Monitoring guide documents the bounded error taxonomy for alerting without message parsing
The system SHALL document the shared machine-readable error codes used across telemetry, logs, MCP, WebSocket, HTTP, and CLI so operators can alert on codes (e.g., `:model_loading`, `:embeddings_unavailable`, `:queue_backpressure`, `:inference_timeout`, `:provider_unreachable`) instead of parsing error messages.

#### Scenario: Operator creates an alert on provider unavailability
- **WHEN** an operator configures an alert for remote inference provider failures
- **THEN** the guide identifies the error code to match and confirms it appears in telemetry, logs, and transport responses identically