# Spec Delta

## Purpose

Lets agents reason about a live system, not just its sources, by exposing bounded read-only BEAM runtime snapshots as queryable context.

## ADDED Requirements

### Requirement: Read-only runtime snapshots
The system SHALL provide an explicit snapshot operation that captures a point-in-time view of the BEAM runtime: nodes, applications, supervisors and their children, process counts with reductions and mailbox lengths, ETS table names with sizes, memory breakdown, recent telemetry counters, and recent crash reasons. Snapshots SHALL be read-only and SHALL never start, stop, or message application processes as a side effect. Each snapshot SHALL carry a captured-at timestamp and SHALL be queryable as context without requiring a language model.

#### Scenario: Capture a runtime snapshot
- **WHEN** a caller captures runtime context on a running node
- **THEN** the result includes applications, a supervisor tree excerpt, process counts, ETS sizes, and memory figures with a timestamp
- **AND** no application process is restarted or messaged by the capture

#### Scenario: Diagnose a slow queue from a snapshot
- **WHEN** an Oban queue slows and a snapshot is captured
- **THEN** the snapshot exposes queue depth alongside scheduler utilization, mailbox lengths, and database latency counters sufficient to distinguish a backed-up queue from slow execution

### Requirement: Bounded and redacted runtime dimensions
Snapshots SHALL contain only bounded dimensions: process names, registered names, MFA for current function, counts, sizes, reductions, mailbox lengths, and crash reasons. Snapshots SHALL NOT contain message bodies, ETS contents, document content, credentials, or tokens. An oversized runtime (many processes or tables) SHALL be truncated with a truncation flag rather than failing or growing without bound.

#### Scenario: Snapshot redacts sensitive content
- **WHEN** processes hold messages containing tokens and ETS tables hold user data
- **THEN** the snapshot reports mailbox lengths and table sizes but never message bodies, table contents, or credentials

#### Scenario: Large runtime truncates safely
- **WHEN** the node hosts more processes than the snapshot bound
- **THEN** the snapshot returns the first N entries ordered deterministically plus `truncated: true`
- **AND** the call still succeeds

### Requirement: Snapshot failures do not disturb the store
A snapshot that cannot reach a node or table SHALL return a classified error for that part and SHALL NOT terminate the caller, crash the store, or write partial snapshot documents into the context tree. Ordinary `read/write/search` operations SHALL remain unaffected by a failed snapshot.

#### Scenario: Unreachable node reports an error
- **WHEN** a snapshot targets a node that is down
- **THEN** the caller receives `{:error, {:node_unreachable, node}}`
- **AND** subsequent store reads and writes still succeed
