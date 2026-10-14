# Spec Delta

## ADDED Requirements

### Requirement: The vector index is derived, never authoritative
The vector index SHALL be derived data that may lag the authoritative record. A vector hit SHALL be surfaced only when the authoritative record still holds the URI it names, so a removed URI SHALL NOT be returned by vector search while a row naming it survives in the index. Removal SHALL make a URI unsearchable and SHALL reclaim its index rows; it SHALL NOT require the index to agree at the instant of removal.

#### Scenario: A removed URI is not returned while its index row survives
- **WHEN** a document is embedded and then removed, and the removal leaves a row naming its URI in the vector index
- **THEN** a vector search does not return that URI
- **AND** the search succeeds normally for unrelated documents

#### Scenario: Index rows for a removed URI are reclaimed
- **WHEN** removal leaves rows naming URIs the authoritative record no longer holds
- **THEN** a reclamation pass deletes those rows
- **AND** rows naming URIs the record still holds are left untouched
- **AND** the reclamation does not require a restart

#### Scenario: Index drift does not block search for unaffected scopes
- **WHEN** the index holds rows naming absent URIs
- **THEN** a vector search over a scope with no drift returns its full ranked result set

### Requirement: A write retires its URI's previous vector
A write at a URI that already holds a vector SHALL retire that vector, so a live document is never ranked by content it no longer has. Retiring derived data that will be regenerated SHALL NOT cause a search to return content the store no longer holds.

#### Scenario: A re-written document is not ranked on its previous content
- **WHEN** a document at a URI is embedded, and a different document is then written at the same URI without a removal having occurred
- **THEN** a vector search does not return that URI on the basis of the previous document's embedding
- **AND** once the new document's own embedding is indexed, a vector search may return it

#### Scenario: Re-writing without a prior embedding behaves as a fresh write
- **WHEN** a document is written at a URI that holds no vector
- **THEN** the write succeeds
- **AND** no vector row exists for the URI until its own embedding is indexed

### Requirement: Vector search honours its limit despite index drift
The store SHALL return up to `top_k` results even when the index holds rows naming URIs the store no longer holds, because a row that cannot be hydrated is dropped rather than counted. A scope whose index has drifted SHALL NOT be silently starved of results.

#### Scenario: Unhydratable rows do not consume the result limit
- **WHEN** a vector search requests `top_k: 5` and the index returns candidates among which several name URIs the store no longer holds
- **THEN** the search returns up to 5 results the store can hold
- **AND** the count is not reduced merely because some candidates could not be hydrated

#### Scenario: A scope without drift returns exactly what it holds
- **WHEN** a vector search requests `top_k: 5` over a scope holding 5 documents with indexed embeddings and no drift
- **THEN** the search returns those 5 results in ranked order

### Requirement: Index backpressure is retryable and contained
When the index cannot accept work because it already holds its maximum number of concurrent operations, the store SHALL report a retryable unavailability that a caller can distinguish from an index that cannot be queried at all and from an invalid query. A failure inside the index SHALL be contained and SHALL NOT terminate the caller, a background worker, or a connection.

#### Scenario: Saturation is reported as retryable
- **WHEN** the index refuses a read or a write because it already holds its maximum number of concurrent operations
- **THEN** the store reports the vector index as unavailable for retry
- **AND** the report is distinguishable from an invalid query and from an index that cannot be queried at all

#### Scenario: An internal index failure does not terminate the caller
- **WHEN** the index raises an internal failure during a search or during an embedding write
- **THEN** the caller receives an error result
- **AND** neither the calling process nor a background worker terminates
