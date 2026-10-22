# Spec Delta

## MODIFIED Requirements

### Requirement: Console is a navigable multi-page surface
The console SHALL present its features as task-scoped pages under `/admin/*`: an overview (health, models, queue, runtime, per-operation statistics, and recent changes), documents (paged tree-root listing plus recursive show-all listing, document search, grouping, and enable/disable), storage (storage footprint, cache, and index coverage), skills (Agent Skills import plus installed-skill inventory with search, show-all, grouping, and enable/disable), sessions (session lookup by ID), and memories (what the store holds as memory, including what is waiting for review). Every page SHALL share a persistent navigation that lists the pages and indicates the current page. Every page SHALL share a persistent header bar showing product identity, the current page title, and a sidebar toggle control. The sidebar navigation SHALL be hideable: an operator can hide it for a full-width content view and restore it, and the hidden/shown choice SHALL persist for the session across console pages without a full page reload. Navigating between console pages SHALL NOT require a full page reload. A console page SHALL load its sections once per visit, and SHALL NOT repeat the same read on the initial render.

#### Scenario: The console lands on the overview
- **WHEN** an operator visits `/admin`
- **THEN** the overview page renders and the navigation indicates it as the current page

#### Scenario: Navigation lists every page and marks the current one
- **WHEN** an operator views any console page
- **THEN** the navigation lists Overview, Documents, Storage, Skills, Sessions, and Memories
- **AND** the page currently being viewed is visually indicated

#### Scenario: Every former console feature remains reachable
- **WHEN** an operator needs a feature that the single console page previously showed
- **THEN** that feature is reachable on exactly one console page: overview, documents, storage, skills, sessions, or memories

#### Scenario: The document editor remains reachable
- **WHEN** an operator follows a document link from the documents page
- **THEN** the document editor opens under `/admin/documents/:id/edit` with the same navigation available

#### Scenario: Skills inventory reachable on skills page
- **WHEN** an operator visits `/admin/skills`
- **THEN** the installed-skill inventory (search, show-all listing, grouping, enable/disable) renders on the same page as skill import without a full page reload

#### Scenario: Header bar is present on every console page
- **WHEN** an operator views any console page including the document editor
- **THEN** a header bar shows product identity, the current page title, and a sidebar toggle control

#### Scenario: Operator hides sidebar for wider view
- **WHEN** an operator activates the sidebar toggle to hide the sidebar
- **THEN** the sidebar collapses out of view and the content region expands to full width without a full page reload

#### Scenario: Sidebar visibility persists across pages
- **WHEN** an operator hides the sidebar and then navigates to another console page
- **THEN** the sidebar stays hidden until the operator restores it

#### Scenario: A page loads its sections once per visit
- **WHEN** an operator opens a console page
- **THEN** each of that page's data sources is read once
- **AND** the page does not repeat the same read before rendering

### Requirement: Full model, queue, and health status
The console SHALL display the full model status already answered by the store: per-role loading state including load-in-progress, last inference latency, memory usage, and configured parameter size. It SHALL display the background-job breakdown by status (`pending`, `running`, `done`, `failed`) and the store health checks. Status SHALL remain answerable while a model loads and SHALL indicate loading rather than appearing simply unloaded. A queue that cannot be read SHALL be reported as unreadable rather than as an empty queue.

#### Scenario: Operator sees model loading state
- **WHEN** a model is being downloaded or loaded and an operator views `/admin`
- **THEN** the console indicates a load is in progress for that role instead of showing it as simply not loaded

#### Scenario: Operator sees latency, memory, and queue depth
- **WHEN** an operator views `/admin`
- **THEN** the console shows last inference latency, memory usage, configured model size, and per-status job counts

#### Scenario: Operator sees health at a glance
- **WHEN** an operator views `/admin`
- **THEN** the console shows whether the database and models are usable per check

#### Scenario: An unreadable queue is not an empty queue
- **WHEN** the queue cannot be read
- **THEN** the console reports that the queue state is unavailable
- **AND** it does not present the queue as idle

### Requirement: Storage footprint and node counts
The console SHALL display the store's storage footprint and tree composition from the operator facade: the database and write-ahead-log byte sizes when the storage provider exposes them, and counts of documents and directories overall and for each top-level subtree. These values SHALL be read-only and SHALL NOT alter store state. A count that could not be read SHALL be reported as unavailable rather than as zero.

#### Scenario: Footprint is visible
- **WHEN** an operator views the console
- **THEN** the console reports the database and WAL sizes when available and the document and directory counts

#### Scenario: Per-subtree composition is visible
- **WHEN** documents exist under multiple top-level subtrees
- **THEN** the console reports a count for each top-level subtree without exposing document content

#### Scenario: An unreadable count is not reported as zero
- **WHEN** the document count cannot be read
- **THEN** the console reports that the count is unavailable
- **AND** it does not present the store as holding no documents

### Requirement: Index coverage
The console SHALL display coverage for the store's indexes: whether the vector index is available and how many vectors it holds relative to indexed documents, how many code-index documents are stored, and how many Hex-doc packages locked by the project are indexed and how many of them are covered. The console SHALL display the vector index's drift signals: which dimension table is active, how many indexed rows name documents the store no longer holds, and how many documents are missing from the active dimension table. Coverage SHALL be read-only and SHALL be answerable when a model or index is unavailable, indicating unavailability rather than failing.

#### Scenario: Vector index coverage is visible
- **WHEN** the vector index is available
- **THEN** the console reports its row count and the number of indexed documents

#### Scenario: Unavailable index is reported, not raised
- **WHEN** the vector index or a model is unavailable
- **THEN** the console indicates the index is unavailable and still renders the rest of the console

#### Scenario: Code and Hex coverage are visible
- **WHEN** code-index documents or Hex-doc documents exist
- **THEN** the console reports how many are indexed, and for Hex how many locked packages are covered

#### Scenario: The locked package count is reported
- **WHEN** the project locks packages that are covered by the Hex-doc index
- **THEN** the console reports how many packages are locked
- **AND** it does not report a locked count of zero while covered packages exist

#### Scenario: Index drift is visible
- **WHEN** the vector index holds rows naming documents the store no longer holds, or documents are missing from the active dimension table
- **THEN** the console reports the active dimension and the drift counts
- **AND** an operator can tell that the index needs a prune or a backfill

### Requirement: Runtime liveness
The console SHALL display node uptime, supervisor and process counts, and a bounded list of recent operational errors with their classified reason and operation, so an operator can tell a healthy store from one that is repeatedly failing. The recent-errors list SHALL be bounded, in memory only, and SHALL NOT contain document content, prompts, users, or credentials. Each listed failure SHALL carry the store's classified reason for that failure, so that two different failures are not reported under the same indistinguishable reason.

#### Scenario: Uptime and process counts are visible
- **WHEN** an operator views the console
- **THEN** the console reports the node's uptime and its supervisor and process counts

#### Scenario: Recent errors are visible without sensitive data
- **WHEN** operations have failed recently
- **THEN** the console lists a bounded number of recent failures with their operation and classified reason
- **AND** no entry contains document content, prompts, user identifiers, or credentials

#### Scenario: Distinct failures carry distinct reasons
- **WHEN** two recent failures had different causes
- **THEN** the console reports each with its own classified reason
- **AND** the reasons are not the same generic value

### Requirement: Console errors rendered from the shared taxonomy
The console SHALL render store failures from the same machine-readable error classification used by the other transports rather than printing raw internal terms, so an operator sees a stable reason without leaking store internals. A console section whose read failed SHALL render that failure rather than presenting an empty result as though the store had nothing.

#### Scenario: Store failure renders a classified reason
- **WHEN** a search, read, removal, or import fails in the console
- **THEN** the console shows a classified reason from the shared taxonomy
- **AND** it does not print a raw `inspect/1` of the failure term

#### Scenario: A failed read is not an empty result
- **WHEN** a console section's read fails
- **THEN** the console reports the classified failure for that section
- **AND** it does not present the section as empty

## ADDED Requirements

### Requirement: The console reports per-operation statistics
The console SHALL display, on the overview page, the store's per-operation statistics: how many times each operation has succeeded and failed, its latency distribution, and its error rate. These statistics SHALL come from the store's retained statistics rather than being recomputed by the console, and SHALL be bounded in size so the page remains readable.

#### Scenario: Operation counts are visible
- **WHEN** an operator views the overview page
- **THEN** the console reports the success and failure count for each tracked operation

#### Scenario: Latency and error rate are visible
- **WHEN** an operation has run repeatedly
- **THEN** the console reports its latency percentiles and its error rate

#### Scenario: A failing operation is identifiable
- **WHEN** an operation has a non-zero failure count
- **THEN** an operator can identify which operation is failing from the overview page alone

### Requirement: The console reports what the store holds as memory
The console SHALL provide a page reporting the memories the store holds: how many there are per type, how many are active, superseded, or waiting for review, and which memories are waiting for review with their URI and value. From that page an operator SHALL be able to promote a waiting memory or reject it, and SHALL be able to forget a memory. Every action the operator takes SHALL be reported back on the page with its outcome.

#### Scenario: Memory counts are visible
- **WHEN** memories of several types exist
- **THEN** the console reports how many of each type are held and how many are waiting for review

#### Scenario: Waiting memories are listed
- **WHEN** memories are waiting for review
- **THEN** the console lists them with their URI and value

#### Scenario: An operator promotes a waiting memory
- **WHEN** an operator promotes a waiting memory from the console
- **THEN** the memory becomes the active assertion at its URI
- **AND** the console reports the outcome

#### Scenario: An operator rejects a waiting memory
- **WHEN** an operator rejects a waiting memory from the console
- **THEN** the waiting memory is removed
- **AND** the console reports the outcome

#### Scenario: An operator forgets a memory
- **WHEN** an operator forgets a memory from the console
- **THEN** the memory and its provenance are removed
- **AND** the console reports the outcome

### Requirement: Console reads are bounded and repeated once
A console page that expands a per-item detail view SHALL NOT issue a separate read per item to build that view. The page SHALL obtain the detail for its items in a bounded number of reads. A console page's periodic refresh SHALL NOT repeat work whose result cannot have changed.

#### Scenario: A per-item detail view does not read per item
- **WHEN** an operator expands a detail view covering many items
- **THEN** the page issues a bounded number of reads to build it
- **AND** it does not issue one read per item

#### Scenario: A refresh does not repeat unchanged work
- **WHEN** a console page refreshes on its timer
- **THEN** it does not re-read data that the refresh cannot have changed
