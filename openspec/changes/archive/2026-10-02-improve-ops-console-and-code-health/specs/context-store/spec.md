# Spec Delta

## MODIFIED Requirements

### Requirement: Keyword search
The store SHALL provide case-insensitive substring keyword search over document content and summaries, optionally scoped to a subtree URI prefix, returning matching URIs with their matched document data. Keyword results SHALL be bounded by the requested `:top_k` (default 10, maximum 200), matching the `search/2` contract, and the bound SHALL be applied in storage rather than after materializing every match; results SHALL be returned in a deterministic order. A `:top_k` outside the accepted range SHALL return `{:error, {:invalid_limit, value}}` rather than fall back to a default, because a default would silently answer a different question than the one asked. This bounding is a breaking change for a caller that relied on an unbounded keyword result set. The store SHALL ALSO provide vector similarity search (see `vector-search` capability) and hybrid search combining both signals.

#### Scenario: Search scoped to subtree
- **WHEN** documents exist under `viking://resources/p/` containing the term "nif" and elsewhere not containing it
- **THEN** searching "NIF" scoped to `viking://resources/p/` returns only URIs under that prefix

#### Scenario: Case-insensitive match
- **WHEN** a document contains "SQLite" and the caller searches "sqlite"
- **THEN** the document URI is returned

#### Scenario: Keyword results honor top_k
- **WHEN** more documents match a keyword query than the requested `:top_k`
- **THEN** no more than `:top_k` results are returned
- **AND** when `:top_k` is omitted, at most the default of 10 results are returned

#### Scenario: Out-of-range top_k is refused
- **WHEN** a caller asks for `:top_k` of zero, a negative number, or more than the maximum
- **THEN** the search returns `{:error, {:invalid_limit, value}}`
- **AND** it does not silently search with a different bound

#### Scenario: Vector search mode
- **WHEN** caller searches with `mode: :vector` and query "machine learning"
- **THEN** results are ranked by cosine similarity to query embedding
- **AND** each result includes similarity score

#### Scenario: Hybrid search mode
- **WHEN** caller searches with `mode: :hybrid`
- **THEN** results combine keyword and vector scores via reciprocal rank fusion
- **AND** ranking reflects both exact matches and semantic similarity
