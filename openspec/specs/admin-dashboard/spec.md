# admin-dashboard Specification

## Purpose
Gives operators a realtime, information-rich operations console at `/admin` that reflects store changes as they happen instead of on a polling delay.

## Requirements

### Requirement: Console reflects store changes in realtime
The console's pages SHALL reflect committed writes, subtree removals, skill replacements, and session commits without requiring a manual reload or waiting for a full poll interval. Each page that shows live store state SHALL subscribe to context changes on connect and update its own sections when a change event arrives; the recent-change feed on the overview SHALL record URI, kind, and version. A periodic refresh SHALL remain as a fallback for missed events or reconnects. Subscription lifetime SHALL follow the viewer session; a restart SHALL require resubscribing and SHALL NOT replay missed events.

#### Scenario: Write appears without manual reload
- **WHEN** an operator views a console page and a document is written elsewhere in the store
- **THEN** the page updates the sections it shows and the overview's recent-change feed within a bounded delay without a manual reload

#### Scenario: Removal and skill replacement appear without manual reload
- **WHEN** an operator views a console page and a subtree is removed or a skill is replaced
- **THEN** the affected page removes or updates the affected entries and the overview records the change kind as `removed` or `replaced`

#### Scenario: Session commit appears without manual reload
- **WHEN** an operator views a console page and a session is committed to a destination URI
- **THEN** the overview records a `committed` change for that destination URI

#### Scenario: Fallback refresh still converges
- **WHEN** a change event is missed (e.g., brief disconnect)
- **THEN** the next periodic refresh converges each page to current store state

### Requirement: Console is a navigable multi-page surface
The console SHALL present its features as task-scoped pages under `/admin/*`: an overview (health, models, queue, runtime, and recent changes), documents (the paged tree-root listing and document search), storage (storage footprint, cache, and index coverage), skills (Agent Skills import), and sessions (session lookup by ID). Every page SHALL share a persistent navigation that lists the pages and indicates the current page. Navigating between console pages SHALL NOT require a full page reload.

#### Scenario: The console lands on the overview
- **WHEN** an operator visits `/admin`
- **THEN** the overview page renders and the navigation indicates it as the current page

#### Scenario: Navigation lists every page and marks the current one
- **WHEN** an operator views any console page
- **THEN** the navigation lists Overview, Documents, Storage, Skills, and Sessions
- **AND** the page currently being viewed is visually indicated

#### Scenario: Every former console feature remains reachable
- **WHEN** an operator needs a feature that the single console page previously showed
- **THEN** that feature is reachable on exactly one console page: overview, documents, storage, skills, or sessions

#### Scenario: The document editor remains reachable
- **WHEN** an operator follows a document link from the documents page
- **THEN** the document editor opens under `/admin/documents/:id/edit` with the same navigation available

### Requirement: Console renders with its current stylesheet
The console's pages SHALL be served with a stylesheet generated from the console's current markup that includes a base reset, so the classes the pages use are present and browser-default element styling does not leak through. The stylesheet build SHALL be reproducible by a documented project command rather than requiring an undocumented manual step.

#### Scenario: Console pages render styled
- **WHEN** an operator loads any console page
- **THEN** the served stylesheet contains the layout classes the page uses
- **AND** the page renders with the console's intended layout rather than unstyled content

#### Scenario: The linked stylesheet and script are served
- **WHEN** a browser requests the stylesheet or script a console page links
- **THEN** the server responds with the asset rather than a 404

#### Scenario: Browser defaults do not leak into console pages
- **WHEN** an operator loads any console page
- **THEN** body spacing, list markers, and form controls follow the console's stylesheet rather than the browser's defaults

#### Scenario: The editor and error pages share the console's stylesheet
- **WHEN** an operator opens the document editor or an error page
- **THEN** the page is served the console's stylesheet and renders with its intended layout

#### Scenario: The stylesheet build is reproducible
- **WHEN** a developer runs the documented asset build command after changing console markup
- **THEN** the generated stylesheet includes the classes the new markup uses

### Requirement: Operator feedback is rendered on console pages
A console page SHALL render the feedback it sets for an operator, so the outcome of an action is visible without leaving the page. A page SHALL NOT discard the feedback it set.

#### Scenario: A successful action reports its outcome
- **WHEN** an operator performs an action that succeeds, such as publishing a document
- **THEN** the console shows a success message for that action
- **AND** the message is visible on the page the operator is left on

#### Scenario: A failed action reports a classified reason
- **WHEN** an operator performs an action that fails, such as publishing a document
- **THEN** the console shows a failure message derived from the shared error taxonomy
- **AND** the message contains no raw `inspect/1` of the failure term

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

### Requirement: Full model, queue, and health status
The console SHALL display the full model status already answered by the store: per-role loading state including load-in-progress, last inference latency, memory usage, and configured parameter size. It SHALL display the background-job breakdown by status (`pending`, `running`, `done`, `failed`) and the store health checks. Status SHALL remain answerable while a model loads and SHALL indicate loading rather than appearing simply unloaded.

#### Scenario: Operator sees model loading state
- **WHEN** a model is being downloaded or loaded and an operator views `/admin`
- **THEN** the console indicates a load is in progress for that role instead of showing it as simply not loaded

#### Scenario: Operator sees latency, memory, and queue depth
- **WHEN** an operator views `/admin`
- **THEN** the console shows last inference latency, memory usage, configured model size, and per-status job counts

#### Scenario: Operator sees health at a glance
- **WHEN** an operator views `/admin`
- **THEN** the console shows whether the database and models are usable per check

### Requirement: Recent-change feed and session lookup without new indexes
The console SHALL show a recent-change feed carrying only URI, change kind (`written | removed | replaced | committed`), and monotonic version for the latest events, and SHALL NOT display document content, prompts, or credentials in the feed. It SHALL allow looking up a session by ID to view its messages. The console SHALL NOT require a new store-wide session index; listing sessions beyond direct lookup is out of scope.

#### Scenario: Recent changes are visible with kind and version
- **WHEN** changes occur while an operator views `/admin`
- **THEN** the feed lists each changed URI with its kind and version in reverse-chronological order, bounded to recent entries

#### Scenario: Feed carries no content
- **WHEN** change events arrive for documents holding different content or users
- **THEN** the feed shows only URI, kind, and version and never document content or secrets

#### Scenario: Operator looks up a session by ID
- **WHEN** an operator enters a session ID
- **THEN** the console shows that session's messages or reports that the session was not found

### Requirement: Existing console surface and trust boundary preserved
The console SHALL remain served under `/admin` through the existing browser pipeline with its current protections; every console page SHALL live under `/admin/*` in the same pipeline. The console SHALL reach the store only through the existing operator facade with no new network routes or authentication bypass. Existing skill-import, edit, and delete behavior SHALL remain unchanged.

#### Scenario: Console stays at /admin with same protections
- **WHEN** an operator visits `/admin` or any console page under `/admin/*`
- **THEN** the request flows through the existing browser pipeline with its session, CSRF, and auth behavior unchanged

#### Scenario: Skill import still works as before
- **WHEN** an operator imports skills through the console
- **THEN** per-skill outcomes (imported, replaced, failed with reason) are reported exactly as today

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
