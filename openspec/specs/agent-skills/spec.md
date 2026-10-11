## Purpose

Allows users to import portable Agent Skills and their supporting files into AgentDb's per-user skills tree, from either the operations UI or a local command-line workflow.

## Requirements

### Requirement: Import skills from folders and tar archives
The system SHALL allow an operator to import Agent Skills through both the admin UI and a local Mix task, from either a local folder or a TAR or gzip-compressed TAR archive. A source SHALL contain either one skill directory with a `SKILL.md` at its root, or a collection directory/archive containing one or more immediate skill directories, each with a `SKILL.md`. An archive MAY include one common top-level wrapper directory. The operator SHALL select a user ID, and each imported skill SHALL be stored below `viking://user/{user_id}/skills/{skill_name}`. The UI and CLI SHALL use the same import behavior and report the outcome for every skill. The UI SHALL acknowledge a file or folder selection before submit by listing the selected entries with their progress and any entry errors.

#### Scenario: Import one folder skill from the CLI
- **WHEN** an operator imports a skill directory containing `SKILL.md` and nested reference files with the Mix task for user `alice`
- **THEN** the skill is available below `viking://user/alice/skills/{skill_name}`
- **AND** its files retain their relative paths and contents

#### Scenario: Import a collection archive from the UI
- **WHEN** an operator uploads a TAR archive containing multiple skill directories, each with `SKILL.md`, and selects user `alice`
- **THEN** every skill is imported below `viking://user/alice/skills/`
- **AND** the UI reports the result for each skill

#### Scenario: Accept a single enclosing archive directory
- **WHEN** a valid TAR archive contains all skill entries beneath one common top-level directory
- **THEN** the importer recognizes the skills beneath that wrapper and imports them using the same destination layout

#### Scenario: Selection lists entries before submit
- **WHEN** an operator selects a skills folder or archive in the UI form
- **THEN** the form lists the selected entries with progress without requiring submit
- **AND** an entry the upload config rejects is reported at the form before submit

### Requirement: Preserve skill files and relative paths
A skill SHALL be identified by a directory containing a UTF-8 `SKILL.md`, and its directory name SHALL be used as the skill name. The importer SHALL preserve every regular UTF-8 text file in the skill directory, including `SKILL.md`, at the same relative path below the destination skill URI. The importer SHALL reject a skill whose name is not a valid single URI segment or whose file contents are not valid UTF-8; it SHALL NOT silently omit such files.

#### Scenario: Preserve nested skill resources
- **WHEN** a skill contains `SKILL.md`, `references/guide.md`, and `scripts/check.py`
- **THEN** the importer stores each file at the corresponding path below `viking://user/{user_id}/skills/{skill_name}`
- **AND** reading each stored URI returns the source file's text unchanged

#### Scenario: Reject an invalid skill name or non-text file
- **WHEN** a source contains a skill directory name that cannot be represented as one valid URI segment or contains a non-UTF-8 file
- **THEN** the import reports the invalid entry
- **AND** no file from that source import is written

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

### Requirement: Validate imports before changing stored data
The system SHALL validate the complete source structure before changing the store. It SHALL reject malformed archives, missing or duplicate skill roots, duplicate normalized file paths, absolute paths, path traversal segments, backslashes, control characters, symbolic links, hard links, and non-regular tar entries. It SHALL enforce finite limits on file count and expanded content size. A source rejected during validation SHALL leave all destination data unchanged and SHALL return an actionable error to the operator. Operating-system metadata entries (basenames starting with `._` and `.DS_Store` files) SHALL be set aside before validation: they consume no limit budget, take no part in layout checks, and are never stored.

#### Scenario: Reject archive path traversal without writing files
- **WHEN** a TAR entry has an absolute path or a `..` path segment
- **THEN** the import is rejected before any destination skill is modified
- **AND** the UI or CLI reports the invalid entry

#### Scenario: Reject an invalid source as a whole
- **WHEN** a multi-skill folder or archive contains a malformed skill or duplicate path
- **THEN** validation fails before any skill from that source is written
- **AND** existing skills remain unchanged

#### Scenario: Reject an oversized source before writing
- **WHEN** the number of files or expanded content size exceeds the import limits
- **THEN** the import is rejected before any destination skill is modified
- **AND** the operator receives an error identifying the exceeded limit

#### Scenario: Set aside macOS metadata instead of refusing the bundle
- **WHEN** a skill folder, archive, or browser selection contains `._*` sidecar files or `.DS_Store` beside a valid skill
- **THEN** the import succeeds with those entries neither stored nor counted
- **AND** the stored skill holds exactly the skill's own files
- **AND** a source holding only metadata is still refused with no skills stored

### Requirement: Installed-skill inventory listing
The system SHALL provide an inventory of installed skills across users, each entry carrying skill name, owner `user_id`, full skill URI (`viking://user/{user_id}/skills/{skill_name}`), file count, enabled status, and group tag. The inventory SHALL support paged reads (default 50 per page) and name/URI substring search with optional owner scope. Listing SHALL be read-only and SHALL NOT alter store state.

#### Scenario: List all skills across users
- **WHEN** skills exist for users `alice` and `bob` and a caller lists the inventory
- **THEN** every installed skill is returned with its name, owner, full URI, file count, status, and group

#### Scenario: Search skills by name substring
- **WHEN** a caller searches the inventory for "review" and matching and non-matching skills exist
- **THEN** only skills whose name or URI contains "review" are returned

#### Scenario: Empty inventory returns empty list
- **WHEN** no skills are installed and a caller lists the inventory
- **THEN** an empty list is returned rather than an error

### Requirement: Skill enable and disable blocked-from-use
The system SHALL persist an enabled/disabled state per skill root, defaulting to enabled. A disabled skill SHALL stay readable and editable but be excluded from search, recall, and default listings unless explicitly included.

#### Scenario: Disable blocks skill from search but keeps it readable
- **WHEN** an operator disables `viking://user/alice/skills/review` and a caller searches a term that skill contains
- **THEN** that skill's URIs are excluded from search results
- **AND** a direct read of a file in that skill still returns its content

#### Scenario: Re-enable restores skill to search
- **WHEN** an operator re-enables a previously disabled skill after its exclusion was observed
- **THEN** a subsequent search for a term that skill contains returns that skill's URIs again

#### Scenario: Existing skills default to enabled
- **WHEN** skills installed before this change are listed after migration
- **THEN** each reads as enabled unless explicitly disabled since

### Requirement: Skill grouping by owner plus custom tag
The system SHALL report each skill's owner as its default group and persist one custom group tag per skill root. Tags SHALL be at most 64 chars (letters, digits, dash, underscore, slash).

#### Scenario: Assign a custom group to a skill
- **WHEN** an operator assigns group "reviewers" to `viking://user/alice/skills/review`
- **THEN** the inventory reports owner `alice` and custom group "reviewers" for that skill

#### Scenario: Replace preserves status and group
- **WHEN** an operator re-imports a valid skill over a disabled, grouped skill
- **THEN** the replaced skill keeps its disabled status and custom group tag
- **AND** its files are replaced whole per existing replace semantics

#### Scenario: Invalid group tag is refused
- **WHEN** an operator assigns an empty-overlong or illegal-character group tag
- **THEN** the assignment is refused with a classified error and the prior tag is unchanged

### Requirement: Bulk skill enable, disable, and grouping
The system SHALL apply enable, disable, and group-tag assignment to a caller-supplied set of skill URIs (one group, one owner, or one filtered search result) as one bulk action, answering per-skill outcomes plus summary counts. A bulk action SHALL NOT stop at the first failure; every reachable skill SHALL be attempted. A refused bulk set SHALL leave all skill state unchanged.

#### Scenario: Bulk-disable one owner's skills
- **WHEN** an operator bulk-disables all skills for user `alice` while `bob`'s skills exist
- **THEN** every `alice` skill reads as disabled, every `bob` skill is unchanged, and per-skill outcomes plus counts are answered

#### Scenario: Partial bulk failure reports per skill
- **WHEN** a bulk group assignment reaches skills where one fails
- **THEN** each successful skill carries the new tag and the result identifies the failed skill without claiming it succeeded
