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
The console SHALL present its features as task-scoped pages under `/admin/*`: an overview (health, models, queue, runtime, and recent changes), documents (paged tree-root listing plus recursive show-all listing, document search, grouping, and enable/disable), storage (storage footprint, cache, and index coverage), skills (Agent Skills import plus installed-skill inventory with search, show-all, grouping, and enable/disable), and sessions (session lookup by ID). Every page SHALL share a persistent navigation that lists the pages and indicates the current page. Every page SHALL share a persistent header bar showing product identity, the current page title, and a sidebar toggle control. The sidebar navigation SHALL be hideable: an operator can hide it for a full-width content view and restore it, and the hidden/shown choice SHALL persist for the session across console pages without a full page reload. Navigating between console pages SHALL NOT require a full page reload.

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
The console SHALL provide document search over store content with optional subtree scope, showing matching URIs that link to the existing document editor. The console SHALL ALSO provide a recursive paged show-all listing of every document URI with a name/substring filter, bounded to 50 entries per page, with the same invalid-page clamping as the tree-root listing. The existing paged tree-root listing SHALL remain paginated (bounded page size) so large stores stay usable. The reported total document count SHALL be the true number of documents the store holds, not zero or a page-local count. An invalid, non-numeric, zero, negative, or out-of-range page parameter SHALL render a bounded page (the nearest valid page) rather than raising an error or crashing the console. Search failures SHALL be reported in words and SHALL leave the existing listing intact.

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

#### Scenario: Operator shows all documents
- **WHEN** an operator enables show-all on the documents page for a store holding documents in nested subtrees
- **THEN** the console lists document URIs recursively across subtrees one bounded page at a time with navigation to further pages
- **AND** the listing stays paginated at 50 entries per page

#### Scenario: Operator filters the show-all listing
- **WHEN** an operator enters a name/substring filter while showing all documents
- **THEN** the console shows only URIs containing that filter with the same pagination and total reflecting the filtered set

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

### Requirement: Installed-skill inventory with search and show-all
The console SHALL list installed skills across all users as a paged show-all listing (50 per page) with search by skill name or URI substring and optional owner (`user_id`) scope. Each row SHALL show skill name, owner, full skill URI, file count, status (enabled/disabled), and group. Each row SHALL link to its documents where applicable. A refused search or listing SHALL report a classified reason and leave the import form and current listing intact.

#### Scenario: Operator lists all installed skills
- **WHEN** skills exist for more than one user and an operator opens `/admin/skills` with show-all
- **THEN** the console lists each skill with its owner, URI, file count, status, and group one bounded page at a time

#### Scenario: Operator searches skills by name
- **WHEN** an operator enters a skill-name substring and submits on the skills page
- **THEN** the console shows only skills whose name or URI contains that substring with links to their contents

#### Scenario: Empty skill store reports no skills
- **WHEN** no skills are installed and an operator views the skills inventory
- **THEN** the console reports no skills rather than failing

### Requirement: Single and bulk enable/disable for skills and documents
The console SHALL allow enabling and disabling one item, one group, or the current filtered result as one bulk action. Each action SHALL report per-item outcomes plus summary counts from the shared taxonomy.

#### Scenario: Operator disables one skill
- **WHEN** an operator disables a single enabled skill
- **THEN** that skill reads as disabled, is excluded from default listings and search, and remains readable and editable

#### Scenario: Operator bulk-disables a group of documents
- **WHEN** an operator disables all documents in one group
- **THEN** every document in that group reads as disabled and a summary count of succeeded and failed items is shown

#### Scenario: Operator re-enables a disabled document
- **WHEN** an operator re-enables a disabled document
- **THEN** that document is included in default listings and search again

#### Scenario: Failed toggle reports a classified reason
- **WHEN** enabling or disabling an item cannot be served
- **THEN** the console reports the classified reason for that item and keeps the listing intact

### Requirement: Grouping by owner/subtree plus custom group tag
The console SHALL group documents by top-level subtree by default and skills by owner (`user_id`) by default, and SHALL ALSO support an operator-assigned custom group tag per skill root and per document. The listing SHALL offer a group filter and show each row's group. Assigning or clearing a group tag SHALL be available single-item and bulk (group or filtered result) with the same outcome reporting as enable/disable. Group tags SHALL carry only names, never content or secrets.

#### Scenario: Operator views documents grouped by subtree
- **WHEN** documents exist under multiple top-level subtrees and an operator views the documents page
- **THEN** the console groups or labels rows by top-level subtree and offers a group filter

#### Scenario: Operator views skills grouped by owner with custom tag
- **WHEN** skills exist for several users and some carry a custom group tag
- **THEN** the console groups or labels rows by owner by default and shows the custom tag alongside, filterable by either

#### Scenario: Operator assigns a custom group to filtered results
- **WHEN** an operator assigns a group tag to the current filtered skill or document set
- **THEN** every item in that set carries the new tag and a summary count is shown

### Requirement: Console uses a colorful clean visual theme
The console SHALL render sections as cards with colored accents per section kind and consistent status colors for health, state, and feedback, with readable spacing and typography. No information shown today SHALL be removed.

#### Scenario: Sections show color accents
- **WHEN** an operator views any console page
- **THEN** each section card shows its accent header and status values use consistent colors rather than all-gray text

#### Scenario: Feedback remains visible in the new theme
- **WHEN** an operator performs an action that sets feedback
- **THEN** the outcome renders in the header/content area with success and failure colors and stays visible without leaving the page

### Requirement: Document LLM layer view
The console SHALL show an LLM view for one document with its L0 abstract, L1 overview, and L2 full content as separate labeled sections, each with source badge, character count, and unavailable state.

#### Scenario: Operator sees all three layers for a document
- **WHEN** an operator opens the document editor for a stored URI
- **THEN** the page shows L0, L1, and L2 sections with the same text the store returns for abstract, overview, and read

#### Scenario: Layer source and size are visible
- **WHEN** an operator views the document LLM view
- **THEN** each layer shows whether it is stored, fallback-derived, or unavailable, plus its character count

#### Scenario: Missing layer does not break the view
- **WHEN** a layer read fails for a stored document
- **THEN** that section shows an unavailable notice and the other layers still render

#### Scenario: Unsaved draft never alters LLM view
- **WHEN** an operator edits the draft without publishing
- **THEN** the LLM view keeps showing stored layers until publish or a store-driven refresh

### Requirement: Skill LLM layer view
The console SHALL provide a per-skill LLM view reachable from the skills inventory that lists each file under the skill root with its L0, L1, and L2 excerpt plus source and size signals.

#### Scenario: Operator opens LLM view for a skill
- **WHEN** an operator activates the LLM-view control for a skill row
- **THEN** the console lists every file under that skill root URI with its L0, L1, and L2 text or excerpt

#### Scenario: Skill file layers carry source and size
- **WHEN** an operator views a skill LLM view
- **THEN** each file entry shows layer source badges and character counts matching the single-document signals

#### Scenario: Removed skill file converges
- **WHEN** a skill file is removed or the skill is replaced while its LLM view is open
- **THEN** the view updates to current store state via the existing change-event or periodic refresh path

### Requirement: LLM layer views stay read-only inside the console trust boundary
The console SHALL render LLM layer views read-only through the existing operator facade under `/admin/*` with no new network routes, and layer refresh SHALL follow the existing subscribe and periodic-refresh lifecycle.

#### Scenario: No new route or auth bypass
- **WHEN** an operator uses the document or skill LLM view
- **THEN** every read goes through the existing operator facade and the view lives under `/admin/*` with current protections

#### Scenario: Layer refresh follows live lifecycle
- **WHEN** a store change event arrives for the open document or skill subtree
- **THEN** the LLM view reloads its layers without a manual reload and without touching an unsaved draft
