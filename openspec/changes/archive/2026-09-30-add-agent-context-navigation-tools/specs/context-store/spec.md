# Spec Delta

## ADDED Requirements

### Requirement: Bounded path discovery
The store SHALL provide `find/2` to discover files and directories whose URI path (excluding the `viking://` scheme) contains a non-empty literal query of at most 256 characters, case-insensitively. A caller MAY scope the search to a valid URI; results SHALL include the scope node and its descendants, match only complete URI segment boundaries for scope membership, and be returned in deterministic URI order without document content. The operation SHALL return at most the requested `limit` (default 50, maximum 200), reject invalid limits and query lengths, and return an empty list when nothing matches. Query text SHALL be treated literally, including SQL wildcard characters.

#### Scenario: Find paths by name within a subtree
- **WHEN** a caller finds `auth` within `viking://resources/project` and matching files or directories exist both inside and outside that subtree
- **THEN** only entries at the scope URI or beneath it whose URI contains `auth` are returned
- **AND** each result identifies its URI, name, and node kind without returning document content
- **AND** results are ordered by URI

#### Scenario: Find treats query characters literally
- **WHEN** a caller searches for a query containing `%`, `_`, or `\`
- **THEN** those characters match only the same literal characters in stored URIs
- **AND** they do not act as wildcards or alter the query

#### Scenario: Find enforces its result bound
- **WHEN** more entries match than the default or caller-supplied limit
- **THEN** no more than the effective limit is returned
- **AND** a limit outside the range 1 through 200 returns an invalid-limit error

#### Scenario: Find validates its query and scope
- **WHEN** the query is empty or longer than 256 characters, the scope URI is malformed, or the scope does not exist
- **THEN** the operation returns a classified error and performs no writes

### Requirement: Scoped literal content inspection
The store SHALL provide `grep/2` to search full document content (L2) for a non-empty literal query of at most 256 characters, case-insensitively, optionally scoped to a valid URI. Each result SHALL identify the document URI, the one-based line number, and a bounded excerpt containing the match. Results SHALL be ordered by URI and then line number and limited to the requested `limit` (default 50, maximum 200). Abstracts and overviews SHALL NOT count as content matches; existing ranked `search/2` behavior SHALL remain unchanged. Query text SHALL be treated literally rather than as a regular expression or SQL pattern.

#### Scenario: Grep returns matching source lines
- **WHEN** a document contains the query on one or more lines and the caller greps within its subtree
- **THEN** each matching line is returned with the document URI and one-based line number
- **AND** each excerpt contains the match and is no longer than 280 characters
- **AND** only results at the scope URI or beneath it are returned

#### Scenario: Grep searches full content, not summaries
- **WHEN** a query occurs only in a document's abstract or overview
- **THEN** `grep/2` does not return that document
- **AND** `search/2` retains its existing content-and-summary matching behavior

#### Scenario: Grep treats special characters literally and is bounded
- **WHEN** a caller greps for text containing `%`, `_`, `\`, or regular-expression metacharacters
- **THEN** the text is matched literally
- **AND** no more than the effective result limit is returned
- **AND** an invalid limit returns an invalid-limit error

#### Scenario: Grep validates its query and scope
- **WHEN** the query is empty or longer than 256 characters, the scope URI is malformed, or the scope does not exist
- **THEN** the operation returns a classified error and performs no writes
