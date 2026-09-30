# Spec Delta

## Purpose

Gives operators a realtime, information-rich operations console at `/admin` that reflects store changes as they happen instead of on a polling delay.

## ADDED Requirements

### Requirement: Console reflects store changes in realtime

The `/admin` console SHALL reflect committed writes, subtree removals, skill replacements, and session commits without requiring a manual reload or waiting for a full poll interval. The console SHALL subscribe to context changes on connect, update affected sections when a change event arrives, and retain a periodic refresh only as a fallback for missed events or reconnects. Subscription lifetime SHALL follow the viewer session; a restart SHALL require resubscribing and SHALL NOT replay missed events.

#### Scenario: Write appears without manual reload

- **WHEN** an operator views `/admin` and a document is written elsewhere in the store
- **THEN** the console updates the document list/counts and recent-change feed within a bounded delay without a manual reload

#### Scenario: Removal and skill replacement appear without manual reload

- **WHEN** an operator views `/admin` and a subtree is removed or a skill is replaced
- **THEN** the console removes or updates the affected entries and records the change kind as `removed` or `replaced`

#### Scenario: Session commit appears without manual reload

- **WHEN** an operator views `/admin` and a session is committed to a destination URI
- **THEN** the console records a `committed` change for that destination URI

#### Scenario: Fallback refresh still converges

- **WHEN** a change event is missed (e.g., brief disconnect)
- **THEN** the next periodic refresh converges the console to current store state

### Requirement: Searchable documents with preserved pagination

The console SHALL provide document search over store content with optional subtree scope, showing matching URIs that link to the existing document editor. The existing paged tree-root listing SHALL remain paginated (bounded page size) so large stores stay usable. Search failures SHALL be reported in words and SHALL leave the existing listing intact.

#### Scenario: Operator searches documents

- **WHEN** an operator enters a search term and submits
- **THEN** the console shows matching document URIs with links to edit each one

#### Scenario: Large store stays paginated

- **WHEN** an operator browses the document tree of a store holding more documents than one page
- **THEN** the console shows one bounded page at a time with navigation to further pages

#### Scenario: Failed search is reported without losing the listing

- **WHEN** a search cannot be served (e.g., unavailable model for vector mode)
- **THEN** the console reports the reason in words and keeps showing the current document page

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

The console SHALL remain served at `live("/admin")` through the existing browser pipeline with its current protections; any additional views SHALL live under `/admin/*` in the same pipeline. The console SHALL reach the store only through the existing operator facade with no new network routes or authentication bypass. Existing skill-import, edit, and delete behavior SHALL remain unchanged.

#### Scenario: Console stays at /admin with same protections

- **WHEN** an operator visits `/admin` or an additional `/admin/*` view
- **THEN** the request flows through the existing browser pipeline with its session, CSRF, and auth behavior unchanged

#### Scenario: Skill import still works as before

- **WHEN** an operator imports skills through the console
- **THEN** per-skill outcomes (imported, replaced, failed with reason) are reported exactly as today
