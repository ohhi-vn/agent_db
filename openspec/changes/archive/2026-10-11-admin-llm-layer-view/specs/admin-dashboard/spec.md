# Spec Delta

## ADDED Requirements

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
