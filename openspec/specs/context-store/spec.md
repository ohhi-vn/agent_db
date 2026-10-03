## Purpose

An embedded, offline context store for AI agents: a persistent URI-addressed tree (resources, memories, skills), caller-supplied layered summaries (L0/L1) over full content (L2), keyword search, and append-only sessions that can be committed into the tree as context. SQLite is the source of truth; ETS is a disposable read cache.

## Requirements

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

### Requirement: Caller-supplied layered content
The store SHALL store for each document a caller-supplied full content (L2) and optional caller-supplied abstract (L0) and overview (L1). Reading a document's abstract or overview SHALL return the stored L0 or L1 verbatim when present. When caller-supplied L0/L1 are absent, the store SHALL generate them automatically using a local LLM (see `llm-summarization` capability) and store the generated versions. As a final fallback, deterministic caller-independent fallbacks apply (first non-empty line for abstract; first 280 characters of content for overview). LLM generation SHALL occur asynchronously after write acknowledgement.

#### Scenario: Abstract read with caller-supplied L0
- **WHEN** a document is written with content and an explicit abstract
- **THEN** reading the abstract returns the caller-supplied text verbatim

#### Scenario: Abstract fallback when L0 absent
- **WHEN** a document is written with content and no abstract
- **THEN** reading the abstract returns the first non-empty line of the stored content

#### Scenario: Abstract fallback to LLM-generated when L0 absent
- **WHEN** a document is written with content and no abstract
- **THEN** reading the abstract returns the LLM-generated abstract once available
- **AND** before LLM generation completes, returns the first non-empty line of stored content

#### Scenario: Overview fallback to LLM-generated when L1 absent
- **WHEN** a document is written with content and no overview
- **THEN** reading the overview returns the LLM-generated overview once available
- **AND** before LLM generation completes, returns the first 280 characters of content

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

### Requirement: Durable restart recovery
The store SHALL recover the full context tree, sessions, and search capability from SQLite alone after a full process restart, with ETS caches rebuilt lazily on demand.

#### Scenario: Survive restart
- **WHEN** documents and a session are written, the application is stopped and restarted, and the same URIs are read again
- **THEN** all reads return identical content and search still matches the pre-restart documents

### Requirement: Pure offline operation
The store SHALL perform all core operations locally with no mandatory external dependencies. Embedding models and LLMs SHALL run locally on the host machine (CPU or GPU) with weights cached on disk. Network requests SHALL only occur for optional model downloads on first use, and for the optional WebSocket API (see `http-api` capability) when enabled. The store SHALL function fully without network connectivity once models are cached. When a model is not cached and cannot be obtained, the affected operation SHALL report an error and SHALL NOT terminate the calling process, and SHALL NOT leave the store permanently unable to serve later requests.

#### Scenario: No network calls
- **WHEN** any store operation (write, read, search, session commit) runs
- **THEN** no network request is initiated

#### Scenario: No mandatory network calls
- **WHEN** models are cached and HTTP API is disabled
- **THEN** all store operations (write, read, search, session commit) complete without network requests

#### Scenario: Model download on first use
- **WHEN** system starts with no cached models and embedding/summarization is needed
- **THEN** models are downloaded from configured URLs to local cache
- **AND** subsequent operations use cached models without network

#### Scenario: Offline with uncached models reports an error
- **WHEN** a model is not cached and cannot be downloaded because the host is offline
- **THEN** the operation that needed it reports an error
- **AND** the calling process is not terminated
- **AND** store operations that do not require the model continue to succeed

#### Scenario: Unavailable model does not disable the store
- **WHEN** a model failed to load because it was unavailable
- **THEN** later requests that do not require that model are still served normally
- **AND** a later request retries the load rather than inheriting a permanently broken state
### Requirement: Async write acknowledgement
The store SHALL persist a document and all required durable background jobs for that write as one storage outcome before acknowledging success. The store SHALL acknowledge a successful write (`write/3`) before embedding generation and LLM summarization complete. Background jobs SHALL process embedding and summarization asynchronously. Readers SHALL see progressively enhanced content: content (L2) immediately, then abstract/overview (L0/L1) once generated, then vector searchability once embedded. If persistence or enqueueing any required job fails, the operation SHALL return an error and SHALL leave the prior document state, cache state, and queue state unchanged. A caller that has asked for the work to be completed before the write returns SHALL be told which of the three outcomes occurred: the work completed, the work failed, or the work is still outstanding. A failed job SHALL NOT be reported to a synchronous caller as though the work had completed.

#### Scenario: Write returns before embeddings ready
- **WHEN** a caller writes a document with asynchronous writes enabled
- **THEN** `:ok` is returned after the document and all required jobs are durably stored, before inference completes
- **AND** `read/1` returns the content immediately
- **AND** `abstract/1` and `overview/1` return fallback or generated content when ready
- **AND** `search/2` with `mode: :vector` includes the document once its embedding is indexed

#### Scenario: Caller-supplied layers omit unnecessary jobs
- **WHEN** a caller writes a document with a caller-supplied abstract or overview
- **THEN** the supplied layer is stored verbatim
- **AND** no job is enqueued to generate that supplied layer
- **AND** all other required jobs are durably stored before successful acknowledgement

#### Scenario: Enqueue failure rolls back the write outcome
- **WHEN** the store cannot enqueue any required job for a document write
- **THEN** `write/3` returns an error identifying the enqueue failure
- **AND** no partial job set remains
- **AND** a new document is absent, or an existing document retains its prior content and layers
- **AND** cached reads continue to agree with the durable document state

#### Scenario: Synchronous write reports completion honestly
- **WHEN** a caller writes with `async: false` and the background jobs complete
- **THEN** `write/3` returns `:ok`

#### Scenario: Synchronous write reports failure rather than success
- **WHEN** a caller writes with `async: false` and the background jobs for that document fail
- **THEN** `write/3` returns an error
- **AND** it does not report success as though the work had completed

#### Scenario: Synchronous write reports work still outstanding
- **WHEN** a caller writes with `async: false` and the background jobs have not finished within the wait
- **THEN** `write/3` reports that the work is still outstanding
- **AND** it does not report success
### Requirement: Background job processing
The store SHALL maintain a durable job queue (SQLite-backed) for embedding generation and summarization tasks. Jobs SHALL be processed by a background worker pool. Job processing SHALL survive restarts: pending jobs SHALL resume after restart. Failed jobs SHALL be retried with exponential backoff. The retry budget SHALL be reserved for work that can succeed on retry: a job deferred because a model is still loading SHALL be rescheduled without consuming an attempt. A deferred job SHALL remain distinguishable from a completed one and from a failed one.

#### Scenario: Jobs survive restart
- **WHEN** documents are written, generating pending embedding/summarization jobs
- **AND** application restarts
- **THEN** pending jobs resume processing after restart
- **AND** no jobs are lost

#### Scenario: Failed jobs retry
- **WHEN** an embedding job fails with transient error
- **THEN** job is re-queued with exponential backoff
- **AND** other jobs continue processing

#### Scenario: Deferring for an unloaded model does not consume the retry budget
- **WHEN** a job is deferred because its model is still loading, repeatedly
- **THEN** the job is rescheduled and remains eligible
- **AND** its attempt count is not advanced by the deferrals
- **AND** it is not marked failed

#### Scenario: A failed job is distinguishable from a deferred one
- **WHEN** a job has exhausted its attempts and is marked failed
- **AND** another job is deferred because a model is loading
- **THEN** the two jobs are reported as different states
### Requirement: Configuration for models and async behavior
The store SHALL be configurable for: embedding model name/URL, LLM model name/URL, CPU/GPU backend, async vs sync write mode, job worker pool size, model cache directory, HTTP API enablement and port, and the wait applied to a model-dependent request that is made while the model is still loading. A configured CPU/GPU backend SHALL take effect: the models the store loads SHALL be placed on the configured backend rather than on a default chosen independently of that configuration. The configured wait SHALL be honoured, and a caller SHALL never be blocked indefinitely on a model that is still loading.

#### Scenario: Configurable async mode
- **WHEN** configured with `async_writes: false`
- **THEN** `write/3` blocks until embedding and summarization complete
- **WHEN** configured with `async_writes: true` (default)
- **THEN** `write/3` returns immediately

#### Scenario: Configured backend takes effect
- **WHEN** a CPU/GPU backend is configured
- **THEN** both the embedding model and the summarization model are loaded onto that backend
- **AND** the configured value is not read and discarded

#### Scenario: The wait for a loading model is configurable
- **WHEN** a wait is configured for model-dependent requests
- **THEN** a request made while the model is loading waits no longer than that
- **AND** a longer or shorter wait changes how long the caller is held, not whether the model eventually loads
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
