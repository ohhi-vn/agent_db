# Spec Delta

## MODIFIED Requirements

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

### Requirement: Existing console surface and trust boundary preserved
The console SHALL remain served under `/admin` through the existing browser pipeline with its current protections; every console page SHALL live under `/admin/*` in the same pipeline. The console SHALL reach the store only through the existing operator facade with no new network routes or authentication bypass. Existing skill-import, edit, and delete behavior SHALL remain unchanged.

#### Scenario: Console stays at /admin with same protections
- **WHEN** an operator visits `/admin` or any console page under `/admin/*`
- **THEN** the request flows through the existing browser pipeline with its session, CSRF, and auth behavior unchanged

#### Scenario: Skill import still works as before
- **WHEN** an operator imports skills through the console
- **THEN** per-skill outcomes (imported, replaced, failed with reason) are reported exactly as today

## ADDED Requirements

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
The console's pages SHALL be served with a stylesheet generated from the console's current markup, so that the classes the pages use are present when a page is rendered. The stylesheet build SHALL be reproducible by a documented project command rather than requiring an undocumented manual step.

#### Scenario: Console pages render styled
- **WHEN** an operator loads any console page
- **THEN** the served stylesheet contains the layout classes the page uses
- **AND** the page renders with the console's intended layout rather than unstyled content

#### Scenario: The stylesheet build is reproducible
- **WHEN** a developer runs the documented asset build command after changing console markup
- **THEN** the generated stylesheet includes the classes the new markup uses
