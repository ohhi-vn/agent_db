# Spec Delta

## Purpose

Allows users to import portable Agent Skills and their supporting files into AgentDb's per-user skills tree, from either the operations UI or a local command-line workflow.

## ADDED Requirements

### Requirement: Import skills from folders and tar archives
The system SHALL allow an operator to import Agent Skills through both the admin UI and a local Mix task, from either a local folder or a TAR or gzip-compressed TAR archive. A source SHALL contain either one skill directory with a `SKILL.md` at its root, or a collection directory/archive containing one or more immediate skill directories, each with a `SKILL.md`. An archive MAY include one common top-level wrapper directory. The operator SHALL select a user ID, and each imported skill SHALL be stored below `viking://user/{user_id}/skills/{skill_name}`. The UI and CLI SHALL use the same import behavior and report the outcome for every skill.

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
When an imported skill has the same name as a skill already stored for the selected user, the system SHALL replace the complete existing skill subtree, including removal of files absent from the new source. Each skill replacement SHALL be atomic: a failed replacement SHALL leave the prior subtree intact, and a successful replacement SHALL keep the document tree, vector index, pending background jobs, and read cache consistent with the replacement. Replacing a skill SHALL NOT change other skills or content outside that skill subtree. Multi-skill imports SHALL report success or failure per skill.

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

### Requirement: Validate imports before changing stored data
The system SHALL validate the complete source structure before changing the store. It SHALL reject malformed archives, missing or duplicate skill roots, duplicate normalized file paths, absolute paths, path traversal segments, backslashes, control characters, symbolic links, hard links, and non-regular tar entries. It SHALL enforce finite limits on file count and expanded content size. A source rejected during validation SHALL leave all destination data unchanged and SHALL return an actionable error to the operator.

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
