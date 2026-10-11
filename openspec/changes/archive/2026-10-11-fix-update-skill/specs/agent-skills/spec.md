# Spec Delta

## MODIFIED Requirements

### Requirement: Replace a same-name skill as one complete subtree
When an imported skill has the same name as a skill already stored for the selected user, the system SHALL replace the complete existing skill subtree, including removal of files absent from the new source. Each skill replacement SHALL be atomic: a failed replacement SHALL leave the prior subtree intact, and a successful replacement SHALL keep the document tree, vector index, pending background jobs, and read cache consistent with the replacement. Replacing a skill SHALL NOT change other skills or content outside that skill subtree. Multi-skill imports SHALL report success or failure per skill. A same-name re-import through either the admin UI or the Mix task SHALL report status `replaced` and SHALL make subsequent reads, listings, and searches observe the new files.

#### Scenario: Replace an existing skill and remove stale files
- **WHEN** an operator imports a valid skill whose name already exists and whose new source omits a file present in the stored skill
- **THEN** the stored skill's files are replaced by the source files
- **AND** the omitted old file is no longer readable
- **AND** other skill subtrees remain unchanged

#### Scenario: Failed replacement preserves the existing skill
- **WHEN** storage fails while replacing a skill
- **THEN** the existing skill subtree remains readable with its prior contents
- **AND** the result reports that skill as failed

#### Scenario: Report partial outcomes for a multi-skill import
- **WHEN** a collection contains multiple valid skills and replacement of one skill fails
- **THEN** each successfully replaced skill remains imported
- **AND** the result identifies the failed skill without claiming it succeeded

#### Scenario: Update reports replaced on either surface
- **WHEN** an operator re-imports the same skill name for the same user through the admin UI upload/archive or through the Mix task path source
- **THEN** the per-skill result reports status `replaced` (not `imported` or `failed`)
- **AND** reading the skill's files returns the new contents

#### Scenario: Updated skill has no stale cached reads
- **WHEN** an operator warms the read and listing caches and then re-imports the same skill name with changed files
- **THEN** a read of a removed file returns `not_found` rather than stale content
- **AND** a read of a rewritten file returns the new content
- **AND** the skill listing reflects the new file set

#### Scenario: Updated skill queues work for new files only
- **WHEN** a same-name re-import succeeds
- **THEN** pending background jobs exist for the files the new source wrote
- **AND** no pending jobs remain for files the new source removed
