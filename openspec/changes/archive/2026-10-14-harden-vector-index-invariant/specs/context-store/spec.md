# Spec Delta

## MODIFIED Requirements

### Requirement: Subtree removal is complete and durable
The store SHALL provide an operation that removes a node and all of its descendants from the context tree. Removal SHALL be complete across every authoritative store that holds state keyed by URI: after a successful removal, no trace of the removed URIs SHALL remain in the node store, the memory store, the commit bookkeeping, or the pending background job queue, and removal SHALL NOT be observable as partial. Removal SHALL invalidate all cached state for the removed subtree, so that a read through the cached path and a read through the store return the same result. Removal SHALL be durable against background work already in flight: a removed URI SHALL NOT acquire a generated summary or an embedding afterwards. A derived index — one that may be regenerated from what survives removal — SHALL stop surfacing the removed URIs and SHALL have its rows for them reclaimed, but SHALL NOT be required to agree with the node store at the instant of removal. Rejected removals SHALL leave all state untouched. Any additional authoritative store keyed by URI SHALL be brought into agreement with the node store by the same removal, without requiring a change to the removal operation's contract.

#### Scenario: Removing a directory removes its whole subtree
- **WHEN** documents exist at `viking://resources/sub/y.md` and `viking://resources/sub/x/a.md` and the caller removes `viking://resources/sub`
- **THEN** reading `viking://resources/sub/y.md` returns `{:error, :not_found}`
- **AND** reading `viking://resources/sub/x/a.md` returns `{:error, :not_found}`
- **AND** listing `viking://resources/sub` returns `{:error, :not_found}`

#### Scenario: Removal leaves no state in any URI-keyed store
- **WHEN** a document at `viking://resources/sub/a.md` has been embedded and then `viking://resources/sub` is removed
- **THEN** the node store holds no row whose URI is `viking://resources/sub` or begins with `viking://resources/sub/`
- **AND** the vector index does not surface those URIs, and its rows for them are reclaimed by the store's reclamation pass
- **AND** the pending job queue holds no job for those URIs

#### Scenario: Removal is invisible to cached reads
- **WHEN** a caller reads `viking://resources/sub/a.md` and lists `viking://resources/sub` so both are cached, then removes `viking://resources/sub`
- **THEN** a subsequent read of `viking://resources/sub/a.md` returns `{:error, :not_found}`
- **AND** a subsequent list of `viking://resources/sub` returns `{:error, :not_found}`

#### Scenario: Removal does not leave the subtree searchable
- **WHEN** a document under `viking://resources/sub` contains a distinctive term and is embedded, then `viking://resources/sub` is removed
- **THEN** a keyword search for that term does not return any URI under `viking://resources/sub`
- **AND** a vector search does not return any URI under `viking://resources/sub`

#### Scenario: A removed URI does not acquire a summary or embedding afterwards
- **WHEN** a document at `viking://resources/sub/a.md` is written with summarization and embedding jobs still pending, and `viking://resources/sub` is removed before those jobs run
- **THEN** the removed URI has no generated abstract or overview afterwards
- **AND** the vector index does not surface the removed URI

#### Scenario: A recreated URI is not searchable on the previous node's embedding
- **WHEN** a document at `viking://resources/sub/a.md` is embedded, then `viking://resources/sub` is removed, then a different document is written at `viking://resources/sub/a.md` and has not yet been embedded
- **THEN** a vector search does not return `viking://resources/sub/a.md` on the basis of the removed document's embedding
- **AND** once the new document's own embedding is indexed, a vector search may return it

#### Scenario: A derived index does not delay a removal
- **WHEN** a document is embedded and then its subtree is removed, and the removal cannot delete the derived index's row in the same step
- **THEN** the removal succeeds without waiting for the index
- **AND** the removed URI is not surfaced by a vector search afterwards
- **AND** the abandoned row is reclaimed by the store's reclamation pass

#### Scenario: Removing a top-level subtree is allowed
- **WHEN** documents exist under `viking://resources/p` and the caller removes `viking://resources`
- **THEN** the removal succeeds
- **AND** `viking://resources/p` is no longer readable
- **AND** sibling subtrees outside `viking://resources` are unaffected

#### Scenario: Removing a missing URI writes nothing
- **WHEN** a caller removes `viking://resources/does_not_exist`
- **THEN** the store returns `{:error, :not_found}`
- **AND** no state is changed in any store

#### Scenario: Removing the tree root is rejected
- **WHEN** a caller attempts to remove `viking://`
- **THEN** the store returns an error indicating the root cannot be removed
- **AND** the existing tree is left intact
