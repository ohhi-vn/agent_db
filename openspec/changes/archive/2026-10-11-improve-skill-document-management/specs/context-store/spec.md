# Spec Delta — context-store

## ADDED Requirements

### Requirement: Document enable and disable blocked-from-use
The store SHALL persist an enabled/disabled state per document URI, defaulting to enabled. A disabled document SHALL stay readable and editable but be excluded from search, find, grep, and default listings unless explicitly included.

#### Scenario: Disable excludes a document from search but keeps it readable
- **WHEN** a caller disables `viking://resources/p/spec.md` containing a distinctive term and searches that term
- **THEN** that URI is excluded from keyword, vector, and hybrid results
- **AND** a direct read of that URI still returns its content

#### Scenario: Disabled subtree excludes descendants
- **WHEN** a caller disables `viking://resources/p` whose descendants contain a distinctive term and searches that term
- **THEN** no URI at or beneath `viking://resources/p` is returned by default search

#### Scenario: Re-enable restores searchability
- **WHEN** a caller re-enables a disabled document whose embedding is already indexed and searches its distinctive term
- **THEN** that URI is returned again without requiring a rewrite

#### Scenario: Prior documents default to enabled
- **WHEN** documents written before this change are read after migration
- **THEN** each reads as enabled and remains searchable as before

### Requirement: Document group-tag metadata
The store SHALL persist one custom group tag per document or subtree root (empty means ungrouped). Tags SHALL be at most 64 chars (letters, digits, dash, underscore, slash) and SHALL NOT alter content or URIs.

#### Scenario: Assign a custom group to a document subtree
- **WHEN** a caller assigns group "release-1" to `viking://resources/p` and lists that scope
- **THEN** entries beneath it report custom group "release-1" alongside the implicit "resources" group

#### Scenario: Content write preserves group and status
- **WHEN** a caller rewrites content at a grouped, disabled URI
- **THEN** the rewritten document keeps its disabled status and custom group tag

#### Scenario: Removal clears tags for the removed subtree only
- **WHEN** a caller removes `viking://resources/p` carrying a custom tag while `viking://resources/q` exists
- **THEN** no tag rows remain for URIs at or beneath `viking://resources/p`
- **AND** tags for `viking://resources/q` are unchanged

### Requirement: Recursive paged document listing for operations
The store SHALL provide a recursive document listing under a scope URI in deterministic URI order, bounded to a caller-requested page (default 50 per page, max 200). The listing SHALL support substring, status, and group filters with counts reflecting the filtered set.

#### Scenario: Recursive show-all stays paginated
- **WHEN** documents exist in nested subtrees and a caller requests show-all page 1 at 50 per page
- **THEN** at most 50 full URIs in deterministic order are returned with page metadata and the true filtered total

#### Scenario: Filtered show-all reflects the filter
- **WHEN** a caller requests show-all with substring "auth" and disabled-included under `viking://`
- **THEN** only URIs containing "auth" are returned with counts reflecting that filtered set

#### Scenario: Default listing excludes disabled unless asked
- **WHEN** enabled and disabled documents exist and a caller requests show-all without a status option
- **THEN** only enabled documents are returned
- **AND** requesting with disabled-included returns both

### Requirement: Search and recall honor disabled state
Keyword, vector, and hybrid search plus memory recall over the context tree SHALL exclude disabled URIs by default and SHALL include them only when the caller passes an explicit disabled-included option. A search that matches only disabled content SHALL return an empty result set rather than an error. Disabled content SHALL NOT leak through vector similarity, reciprocal-rank fusion, find, or grep defaults.

#### Scenario: Hybrid search excludes disabled by default
- **WHEN** only a disabled document contains the query term and a caller hybrid-searches it without options
- **THEN** an empty result set is returned rather than the disabled URI

#### Scenario: Explicit opt-in returns disabled matches
- **WHEN** the same caller repeats the search with disabled-included
- **THEN** the disabled URI is returned with its rank and score as normal
