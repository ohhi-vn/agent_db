# Spec Delta

## MODIFIED Requirements

### Requirement: Searchable documents with preserved pagination
The console SHALL provide document search over store content with optional subtree scope, showing matching URIs that link to the existing document editor. The existing paged tree-root listing SHALL remain paginated (bounded page size) so large stores stay usable. The reported total document count SHALL be the true number of documents the store holds, not zero or a page-local count. An invalid, non-numeric, zero, negative, or out-of-range page parameter SHALL render a bounded page (the nearest valid page) rather than raising an error or crashing the console. Search failures SHALL be reported in words and SHALL leave the existing listing intact.

#### Scenario: Operator searches documents
- **WHEN** an operator enters a search term and submits
- **THEN** the console shows matching document URIs with links to edit each one

#### Scenario: Large store stays paginated
- **WHEN** an operator browses the document tree of a store holding more documents than one page
- **THEN** the console shows one bounded page at a time with navigation to further pages

#### Scenario: Failed search is reported without losing the listing
- **WHEN** a search cannot be served (e.g., unavailable model for vector mode)
- **THEN** the console reports the reason in words and keeps showing the current document page

#### Scenario: Document count is the true total
- **WHEN** an operator views the console for a store holding documents outside the current page
- **THEN** the console shows the total document count for the listed scope
- **AND** that count is greater than zero when the store holds documents

#### Scenario: Invalid page renders a bounded page
- **WHEN** the console is requested with a page that is non-numeric, zero, negative, or beyond the last page
- **THEN** the console renders the nearest valid page instead of raising
- **AND** the response remains successful

## ADDED Requirements

### Requirement: Storage footprint and node counts
The console SHALL display the store's storage footprint and tree composition from the operator facade: the database and write-ahead-log byte sizes when the storage provider exposes them, and counts of documents and directories overall and for each top-level subtree. These values SHALL be read-only and SHALL NOT alter store state.

#### Scenario: Footprint is visible
- **WHEN** an operator views the console
- **THEN** the console reports the database and WAL sizes when available and the document and directory counts

#### Scenario: Per-subtree composition is visible
- **WHEN** documents exist under multiple top-level subtrees
- **THEN** the console reports a count for each top-level subtree without exposing document content

### Requirement: Cache and BEAM memory visibility
The console SHALL display the size of the store's disposable ETS caches and the current BEAM memory and process/ETS counts from the runtime snapshot, so an operator can distinguish cache growth from real content growth. The values SHALL be bounded and SHALL NOT expose cached document content.

#### Scenario: Cache and memory are visible
- **WHEN** an operator views the console
- **THEN** the console reports each cache table's entry count and memory and the current BEAM memory, process count, and ETS table count

### Requirement: Queue detail and failed jobs
The console SHALL display the background-job breakdown by status, the age of the oldest pending job, and a bounded list of failed jobs carrying the job kind, the affected URI, the attempt count, and the last failure reason. The failure reason SHALL be derived from the store's shared error classification and SHALL NOT contain document content, prompts, or credentials.

#### Scenario: Queue depth and oldest pending age are visible
- **WHEN** pending jobs exist
- **THEN** the console reports per-status counts and the age of the oldest pending job

#### Scenario: Failed jobs are diagnosable
- **WHEN** a background job has exhausted its attempts
- **THEN** the console lists it with its kind, URI, attempt count, and classified failure reason
- **AND** the listed reason contains no document content, prompt, or credential

### Requirement: Index coverage
The console SHALL display coverage for the store's indexes: whether the vector index is available and how many vectors it holds relative to indexed documents, how many code-index documents are stored, and how many Hex-doc packages locked by the project are indexed. Coverage SHALL be read-only and SHALL be answerable when a model or index is unavailable, indicating unavailability rather than failing.

#### Scenario: Vector index coverage is visible
- **WHEN** the vector index is available
- **THEN** the console reports its row count and the number of indexed documents

#### Scenario: Unavailable index is reported, not raised
- **WHEN** the vector index or a model is unavailable
- **THEN** the console indicates the index is unavailable and still renders the rest of the console

#### Scenario: Code and Hex coverage are visible
- **WHEN** code-index documents or Hex-doc documents exist
- **THEN** the console reports how many are indexed, and for Hex how many locked packages are covered

### Requirement: Model operation detail
The console SHALL display, per model role, the load state, the last load duration, the last inference latency, the in-flight inference count, and the configured model identity. For remote providers the console SHALL display provider health where the provider reports it, and SHALL NOT present an unreachable provider as loaded.

#### Scenario: Load duration and in-flight count are visible
- **WHEN** a model has loaded and inferences have run
- **THEN** the console reports the last load duration, last inference latency, and current in-flight count for that role

#### Scenario: Unreachable remote provider is not shown as ready
- **WHEN** a configured remote provider cannot be reached
- **THEN** the console reports it as unhealthy or unavailable rather than loaded

### Requirement: Runtime liveness
The console SHALL display node uptime, supervisor and process counts, and a bounded list of recent operational errors with their classified reason and operation, so an operator can tell a healthy store from one that is repeatedly failing. The recent-errors list SHALL be bounded, in memory only, and SHALL NOT contain document content, prompts, users, or credentials.

#### Scenario: Uptime and process counts are visible
- **WHEN** an operator views the console
- **THEN** the console reports the node's uptime and its supervisor and process counts

#### Scenario: Recent errors are visible without sensitive data
- **WHEN** operations have failed recently
- **THEN** the console lists a bounded number of recent failures with their operation and classified reason
- **AND** no entry contains document content, prompts, user identifiers, or credentials

### Requirement: Console errors rendered from the shared taxonomy
The console SHALL render store failures from the same machine-readable error classification used by the other transports rather than printing raw internal terms, so an operator sees a stable reason without leaking store internals.

#### Scenario: Store failure renders a classified reason
- **WHEN** a search, read, removal, or import fails in the console
- **THEN** the console shows a classified reason from the shared taxonomy
- **AND** it does not print a raw `inspect/1` of the failure term
