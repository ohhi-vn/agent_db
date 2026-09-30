# Spec Delta

## Purpose

Lets one agent hand its stored context to another agent as a single offline tar file that the other store can validate and restore.

## ADDED Requirements

### Requirement: Export store data to a tar archive
The system SHALL provide an export operation that writes context-tree documents (full content plus any caller-supplied abstract/overview), memory provenance (type, confidence, source, supersession chain), and sessions (ordered messages) into a single tar archive at a caller-chosen filesystem path, supporting both plain `.tar` and gzip-compressed `.tar.gz`. The caller MAY restrict the export to a subtree URI scope; when no scope is given the export SHALL cover the full store. The export SHALL include a machine-readable manifest describing format version, exported scope, counts, and checksum.

#### Scenario: Full export then inspectable archive
- **WHEN** a store holding documents, memories, and sessions is exported to `/tmp/backup.tar.gz` with no scope
- **THEN** the operation succeeds and the file exists at that path
- **AND** the archive lists as a valid tar containing a manifest plus the exported documents, memories, and sessions

#### Scenario: Scoped export contains only the subtree
- **WHEN** an export is requested with scope `viking://resources/project`
- **THEN** the archive contains only documents beneath that URI
- **AND** documents outside the scope are absent from the archive

#### Scenario: Export of missing scope fails without a file
- **WHEN** an export is requested with a scope URI that does not exist
- **THEN** the operation returns a `:not_found` error
- **AND** no archive file is created or any existing file at that path is left unmodified

### Requirement: Import tar archive into the store
The system SHALL provide an import operation that reads a previously exported tar archive from a filesystem path or raw bytes and restores its documents, memories, and sessions into the running store. Import SHALL be additive-merge by URI: a URI absent from the store is created, a URI already present is revised in place through the ordinary write path (memories retain supersession history, ordinary documents are overwritten), and sessions already present under the same id are left untouched. Import SHALL NOT delete any store content that is not part of the archive. Re-importing an unchanged archive SHALL converge without duplicating documents, memories, or session messages.

#### Scenario: Export-import round trip preserves content
- **WHEN** a store is exported and the archive is imported into an empty store on another machine
- **THEN** every exported document reads back with identical full content and caller-supplied abstract/overview
- **AND** every exported memory recalls with identical value, type, confidence, and source
- **AND** every exported session returns its messages in original order

#### Scenario: Import merges without deleting unrelated data
- **WHEN** an archive is imported into a store that already holds unrelated URIs
- **THEN** the imported URIs are created or revised
- **AND** the pre-existing unrelated URIs remain readable and unchanged

#### Scenario: Re-import is convergent
- **WHEN** the same archive is imported twice with no changes in between
- **THEN** the second import succeeds
- **AND** document contents, memory recall results, and session message lists are identical after both imports

### Requirement: Validated import refuses unsafe or malformed archives
The system SHALL validate an import archive fully before writing anything, and SHALL refuse the whole archive without side effects when it is malformed or unsafe. Refusal causes SHALL include: unreadable file or bytes, not a tar/gzip-tar archive, missing or invalid manifest, format version newer than supported, unsafe member path (absolute, containing `..`, backslash, empty segment, or control character), symlink/hardlink or non-regular entry, duplicate path, file that is not valid UTF-8, or entry/byte counts exceeding published limits. Every refusal SHALL return a reason that a caller can render as a human-readable sentence.

#### Scenario: Traversal archive is refused whole
- **WHEN** an archive containing a member with a `..` path segment is imported
- **THEN** the operation returns an error naming the unsafe path
- **AND** no document, memory, or session from that archive exists in the store afterwards

#### Scenario: Oversize archive is refused before expansion
- **WHEN** an archive whose declared or actual expanded size exceeds the published byte limit is imported
- **THEN** the operation returns a too-large error naming the limit
- **AND** the store is left exactly as it was

#### Scenario: Corrupt archive reports a reason
- **WHEN** random bytes that are neither tar nor gzip-tar are imported
- **THEN** the operation returns a malformed-archive error
- **AND** the store is unchanged

### Requirement: CLI export and import for agents
The system SHALL provide `mix agent_db.export_data` and `mix agent_db.import_data` tasks accepting a destination/source path plus optional `--scope` (export only) and `--json` flags. With `--json` the task SHALL print the result as JSON to stdout; without it the task SHALL print human-readable lines. Failures SHALL exit non-zero with the reason on stderr, and SHALL leave existing human text output conventions unchanged.

#### Scenario: Agent exports and imports via CLI JSON
- **WHEN** an agent runs `mix agent_db.export_data /tmp/backup.tar.gz --json` then `mix agent_db.import_data /tmp/backup.tar.gz --json` on another checkout
- **THEN** each prints a JSON object naming the archive path and counts
- **AND** a missing source file exits non-zero with the reason on stderr

### Requirement: Imported content behaves like natively written content
Documents, memories, and sessions restored by import SHALL be immediately readable through the ordinary operations (`read`, `abstract`, `overview`, `list`, `tree`, `recall`, `get_session`, `search`, `find`, `grep`), SHALL emit the same change notifications as native writes, and SHALL enqueue embedding generation (and any missing summarization) through the existing background job queue rather than carrying derived embeddings or generated summaries in the archive.

#### Scenario: Imported document is searchable and notifies
- **WHEN** an archive is imported
- **THEN** a keyword search scoped to an imported subtree returns the imported documents
- **AND** subscribers to an imported scope observe change notifications for the restored URIs
