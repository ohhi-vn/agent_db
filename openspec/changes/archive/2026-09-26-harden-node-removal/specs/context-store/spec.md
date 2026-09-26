# Spec Delta

## MODIFIED Requirements

### Requirement: URI-addressed hierarchical context tree
The store SHALL persist a hierarchical context tree addressed by `viking://` URIs with top-level subtrees `resources/`, `user/{user_id}/memories`, `user/{user_id}/resources`, `user/{user_id}/skills`, and `peers/`. Each node SHALL have exactly one parent and be reachable from its root. Operations on a missing URI SHALL return a `:not_found` error without side effects. Listing a URI SHALL return the names of that node's direct children only, never grandchildren, and SHALL report `:not_found` when the URI does not exist. A depth-limited tree projection SHALL return the node's structure down to the requested depth and SHALL report `:not_found` when the URI does not exist.

#### Scenario: Write and read back a document
- **WHEN** a caller writes content to `viking://resources/my_project/docs/api.md`
- **THEN** the content is persisted and a subsequent read of that URI returns the identical content

#### Scenario: Missing URI returns not_found
- **WHEN** a caller reads `viking://resources/does_not_exist`
- **THEN** the store returns `{:error, :not_found}` and writes nothing

#### Scenario: Directory listing reflects writes
- **WHEN** a caller writes `viking://resources/p/docs/a.md` and `viking://resources/p/docs/b.md` then lists `viking://resources/p/docs`
- **THEN** the listing includes both `a.md` and `b.md`

#### Scenario: Listing returns direct children only
- **WHEN** a caller writes `viking://resources/p/docs/a.md` and `viking://resources/p/readme.md` then lists `viking://resources/p`
- **THEN** the listing includes `docs` and `readme.md`
- **AND** it does not include `a.md`, which is a grandchild

#### Scenario: Listing a missing URI returns not_found
- **WHEN** a caller lists `viking://resources/does_not_exist`
- **THEN** the store returns `{:error, :not_found}` and writes nothing

#### Scenario: Tree projection is depth-limited
- **WHEN** documents exist at `viking://resources/t/a/b/deep.md` and the caller requests a tree of `viking://resources/t` at depth 1
- **THEN** the projection contains `a` as a node
- **AND** it does not contain `b` or `deep.md`
- **WHEN** the caller requests the same tree at depth 2
- **THEN** the projection contains `b` and does not contain `deep.md`

#### Scenario: Tree of a missing URI returns not_found
- **WHEN** a caller requests a tree of `viking://resources/does_not_exist`
- **THEN** the store returns `{:error, :not_found}` and writes nothing

#### Scenario: Tree reflects removal
- **WHEN** a caller builds a tree of `viking://resources/t` and then removes `viking://resources/t/a`
- **THEN** a subsequent tree of `viking://resources/t` at the same depth no longer contains `a` or any of its descendants

### Requirement: Sessions with commit-to-context
The store SHALL record sessions as append-only, ordered message lists persisted in SQLite, and SHALL support committing a session into the context tree at a caller-chosen destination URI as a single document whose content is derived from the session's messages in order. Commit SHALL be idempotent per (session, destination) pair: committing a session whose messages have not changed SHALL NOT duplicate or alter the destination document's content. Idempotency SHALL be defined by converged state rather than by a recorded hash alone — if the destination document has been removed, re-committing an unchanged session SHALL restore it and SHALL NOT report the commit as unchanged. A removed destination SHALL NOT retain commit bookkeeping that prevents its content from being restored.

#### Scenario: Append and commit a session
- **WHEN** messages are appended to a session and the session is committed to `viking://user/u1/memories/session-42`
- **THEN** a document exists at that URI containing all messages in order, and re-committing the unchanged session leaves exactly one such document

#### Scenario: Re-commit restores a removed destination
- **WHEN** a session is committed to `viking://user/u1/memories/session-42` and that destination is then removed
- **AND** the session is committed again to the same destination with no new messages
- **THEN** the commit reports the destination URI rather than reporting it as unchanged
- **AND** a document exists at that URI containing all of the session's messages in order
- **AND** the restored document is not duplicated

#### Scenario: Removal clears commit bookkeeping for the destination
- **WHEN** a session has been committed to a destination and that destination is removed
- **THEN** no commit record for that (session, destination) pair remains
- **AND** a later commit of that session to a different destination is unaffected

## ADDED Requirements

### Requirement: Subtree removal is complete and durable
The store SHALL provide an operation that removes a node and all of its descendants from the context tree. Removal SHALL be complete across every store that holds state keyed by URI: after a successful removal, no trace of the removed URIs SHALL remain in the node store, the vector index, or the pending background job queue, and removal SHALL NOT be observable as partial. Removal SHALL invalidate all cached state for the removed subtree, so that a read through the cached path and a read through the store return the same result. Removal SHALL be durable against background work already in flight: a removed URI SHALL NOT acquire a generated summary or an embedding afterwards, and a node later created at a previously removed URI SHALL NOT be returned by vector search until its own embedding has been indexed. Rejected removals SHALL leave all state untouched. Any additional store keyed by URI SHALL be brought into agreement with the node store by the same removal, without requiring a change to the removal operation's contract.

#### Scenario: Removing a directory removes its whole subtree
- **WHEN** documents exist at `viking://resources/sub/y.md` and `viking://resources/sub/x/a.md` and the caller removes `viking://resources/sub`
- **THEN** reading `viking://resources/sub/y.md` returns `{:error, :not_found}`
- **AND** reading `viking://resources/sub/x/a.md` returns `{:error, :not_found}`
- **AND** listing `viking://resources/sub` returns `{:error, :not_found}`

#### Scenario: Removal leaves no state in any URI-keyed store
- **WHEN** a document at `viking://resources/sub/a.md` has been embedded and then `viking://resources/sub` is removed
- **THEN** the node store holds no row whose URI is `viking://resources/sub` or begins with `viking://resources/sub/`
- **AND** the vector index holds no entry for those URIs
- **AND** the pending job queue holds no job for those URIs

#### Scenario: Removal is invisible to cached reads
- **WHEN** a caller reads `viking://resources/sub/a.md` and lists `viking://resources/sub` so both are cached, then removes `viking://resources/sub`
- **THEN** a subsequent read of `viking://resources/sub/a.md` returns `{:error, :not_found}`
- **AND** a subsequent list of `viking://resources/sub` returns `{:error, :not_found}`

#### Scenario: Removal does not leave the subtree searchable
- **WHEN** a document under `viking://resources/sub` contains a distinctive term and is embedded, then `viking://resources/sub` is removed
- **THEN** a keyword search for that term does not return any URI under `viking://resources/sub`

#### Scenario: A removed URI does not acquire a summary or embedding afterwards
- **WHEN** a document at `viking://resources/sub/a.md` is written with summarization and embedding jobs still pending, and `viking://resources/sub` is removed before those jobs run
- **THEN** the removed URI has no generated abstract or overview afterwards
- **AND** the vector index holds no entry for the removed URI

#### Scenario: A recreated URI is not searchable on the previous node's embedding
- **WHEN** a document at `viking://resources/sub/a.md` is embedded, then `viking://resources/sub` is removed, then a different document is written at `viking://resources/sub/a.md` and has not yet been embedded
- **THEN** a vector search does not return `viking://resources/sub/a.md` on the basis of the removed document's embedding
- **AND** once the new document's own embedding is indexed, a vector search may return it

#### Scenario: Removing a missing URI writes nothing
- **WHEN** a caller removes `viking://resources/does_not_exist`
- **THEN** the store returns `{:error, :not_found}`
- **AND** no state is changed in any store

#### Scenario: Removing the tree root is rejected
- **WHEN** a caller attempts to remove `viking://`
- **THEN** the store returns an error indicating the root cannot be removed
- **AND** the existing tree is left intact

#### Scenario: Removing a top-level subtree is allowed
- **WHEN** documents exist under `viking://resources/p` and the caller removes `viking://resources`
- **THEN** the removal succeeds
- **AND** `viking://resources/p` is no longer readable
- **AND** sibling subtrees outside `viking://resources` are unaffected
