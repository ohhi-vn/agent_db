# Spec Delta

## MODIFIED Requirements

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
