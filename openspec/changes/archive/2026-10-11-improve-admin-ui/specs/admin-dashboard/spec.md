# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Console uses a colorful clean visual theme
The console SHALL render sections as cards with colored accents per section kind and consistent status colors for health, state, and feedback, with readable spacing and typography. No information shown today SHALL be removed.

#### Scenario: Sections show color accents
- **WHEN** an operator views any console page
- **THEN** each section card shows its accent header and status values use consistent colors rather than all-gray text

#### Scenario: Feedback remains visible in the new theme
- **WHEN** an operator performs an action that sets feedback
- **THEN** the outcome renders in the header/content area with success and failure colors and stays visible without leaving the page
