# Spec Delta

## MODIFIED Requirements

### Requirement: Write path persists before cache
The store SHALL apply every write to SQLite before acknowledging it, and SHALL NOT allow any ETS cache to serve content newer than SQLite state (no cache-ahead-of-disk). Cache state after a write SHALL equal the state a cold cache would produce from SQLite. This obligation SHALL apply to every path that writes document content, including committing a session to a destination URI, and not only to direct document writes.

#### Scenario: Cache matches disk after write
- **WHEN** a caller writes a document and immediately reads it through the cached path
- **THEN** the read returns the same content as a read through the SQLite fallback path

#### Scenario: Cache matches disk after committing a session
- **WHEN** a caller reads a destination URI so that its content is cached
- **AND** commits a session to that same destination URI, changing its content
- **THEN** a subsequent read of that URI returns the committed content
- **AND** that read returns the same content as a read through the SQLite fallback path
