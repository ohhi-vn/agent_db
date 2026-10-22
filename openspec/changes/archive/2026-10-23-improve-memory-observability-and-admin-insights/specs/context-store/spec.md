# Spec Delta

## MODIFIED Requirements

### Requirement: Write path persists before cache
The store SHALL apply every write to SQLite before acknowledging it, and SHALL NOT allow any ETS cache to serve content newer than SQLite state (no cache-ahead-of-disk). Cache state after a write SHALL equal the state a cold cache would produce from SQLite. This obligation SHALL apply to every path that writes document content, including committing a session to a destination URI, and not only to direct document writes. A read that races a concurrent write to the same URI SHALL NOT leave the cache holding content older than what the write produced, so a subsequent read of that URI returns the written content.

#### Scenario: Cache matches disk after write
- **WHEN** a caller writes a document and immediately reads it through the cached path
- **THEN** the read returns the same content as a read through the SQLite fallback path

#### Scenario: Cache matches disk after committing a session
- **WHEN** a caller reads a destination URI so that its content is cached
- **AND** commits a session to that same destination URI, changing its content
- **THEN** a subsequent read of that URI returns the committed content
- **AND** that read returns the same content as a read through the SQLite fallback path

#### Scenario: A read racing a write does not leave stale content cached
- **WHEN** a read of a URI is in flight while a write to that URI completes
- **THEN** the cache does not afterwards hold the pre-write content for that URI
- **AND** a subsequent read of that URI returns the written content

### Requirement: Bounded content inspection and listing reads
The system SHALL apply the caller's `limit` inside storage for content inspection (`grep`), memory lists, and session lists, and SHALL NOT materialize unbounded rows or document blobs before truncating. Removal of a subtree and recent-error reads SHALL NOT scan entire in-memory tables row by row on the hot path. A subtree-scoped count, enable, disable, or group operation SHALL NOT require a scan of every row in the store.

#### Scenario: Large grep honors limit without loading everything
- **WHEN** thousands of lines match a content query with `limit: 50`
- **THEN** at most 50 results are returned
- **AND** the store transfers only a bounded candidate set from storage, not every matching blob

#### Scenario: Memory and session lists are bounded
- **WHEN** many memories or sessions exist and the caller lists them
- **THEN** the result is bounded and ordered deterministically
- **AND** the store does not load the full table to answer the call

#### Scenario: Removing a subtree does not scan the whole cache
- **WHEN** a subtree is removed
- **THEN** the cache entries beneath it are dropped
- **AND** the drop does not enumerate every key of every cache table

#### Scenario: A subtree operation does not scan the whole store
- **WHEN** a subtree-scoped count, enable, disable, or group operation runs over a store holding many documents
- **THEN** the operation is answered without reading every document row

## ADDED Requirements

### Requirement: The read cache is bounded and observable
The store's in-memory read cache SHALL be bounded: it SHALL NOT grow without limit for the lifetime of a process, and entries that are no longer useful SHALL be eligible for eviction. The store SHALL report the cache's size and its hit and miss counts, so an operator can tell whether the cache is earning the memory it holds. The cache SHALL continue to serve the same content a cold cache would produce from SQLite.

#### Scenario: The cache does not grow without limit
- **WHEN** a long-running process reads many distinct documents
- **THEN** the cache's retained size stays within a fixed bound
- **AND** the least useful entries are evicted rather than accumulating

#### Scenario: Cache effectiveness is reportable
- **WHEN** an operator asks about the cache
- **THEN** the store reports how many reads were served from the cache and how many were not

#### Scenario: Eviction does not change what a read returns
- **WHEN** a cached entry has been evicted
- **THEN** reading that URI still returns the same content as a cold read would

### Requirement: A write is not abandoned at a default timeout
A store write SHALL NOT be abandoned because a default call timeout elapsed while the write was still proceeding. When a write takes longer than a caller-supplied bound, the store SHALL report a retryable classified error and the write's outcome SHALL be unambiguous to the caller: the caller SHALL NOT be told that a write failed while the write in fact landed.

#### Scenario: A slow write reports rather than silently failing
- **WHEN** a write exceeds the caller's time bound
- **THEN** the store reports a classified retryable error
- **AND** it does not report a failure for a write that proceeded

#### Scenario: The caller learns the write's outcome
- **WHEN** a write times out at the caller's bound
- **THEN** the caller can determine whether the write landed
- **AND** a later read of the written URI is consistent with what the caller was told

#### Scenario: A contended write retries within a bound
- **WHEN** the store is contended and the database reports busy
- **THEN** the write waits and retries with growing delay within a bounded timeout rather than failing immediately
- **AND** a write that still cannot proceed returns a retryable classified error, not a crash

### Requirement: Failure of a memory operation is classified and reported
A memory operation that fails SHALL report a reason drawn from the store's shared error classification, and SHALL NOT report the failure as an empty result. A memory operation that cannot be evaluated because a model or the vector index is unavailable SHALL report that the evaluation could not be performed.

#### Scenario: A storage failure is classified
- **WHEN** a memory operation fails because the store cannot answer
- **THEN** the operation reports a classified failure
- **AND** it does not return an empty result set

#### Scenario: An unavailable model is reported, not silent
- **WHEN** a memory operation needs a model that is unavailable
- **THEN** the operation reports that the work could not be performed
- **AND** it does not report that nothing was found
