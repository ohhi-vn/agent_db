# Spec Delta — admin-dashboard

## MODIFIED Requirements

### Requirement: Console is a navigable multi-page surface
The console SHALL present its features as task-scoped pages under `/admin/*`: an overview (health, models, queue, runtime, and recent changes), documents (paged tree-root listing plus recursive show-all listing, document search, grouping, and enable/disable), storage (storage footprint, cache, and index coverage), skills (Agent Skills import plus installed-skill inventory with search, show-all, grouping, and enable/disable), and sessions (session lookup by ID). Every page SHALL share a persistent navigation that lists the pages and indicates the current page. Navigating between console pages SHALL NOT require a full page reload.

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

## ADDED Requirements

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
