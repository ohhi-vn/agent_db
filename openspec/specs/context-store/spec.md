## Purpose

An embedded, offline context store for AI agents: a persistent URI-addressed tree (resources, memories, skills), caller-supplied layered summaries (L0/L1) over full content (L2), keyword search, and append-only sessions that can be committed into the tree as context. SQLite is the source of truth; ETS is a disposable read cache.

## Requirements

### Requirement: URI-addressed hierarchical context tree
The store SHALL persist a hierarchical context tree addressed by `viking://` URIs with top-level subtrees `resources/`, `user/{user_id}/memories`, `user/{user_id}/resources`, `user/{user_id}/skills`, and `peers/`. Each node SHALL have exactly one parent and be reachable from its root. Operations on a missing URI SHALL return a `:not_found` error without side effects.

#### Scenario: Write and read back a document
- **WHEN** a caller writes content to `viking://resources/my_project/docs/api.md`
- **THEN** the content is persisted and a subsequent read of that URI returns the identical content

#### Scenario: Missing URI returns not_found
- **WHEN** a caller reads `viking://resources/does_not_exist`
- **THEN** the store returns `{:error, :not_found}` and writes nothing

#### Scenario: Directory listing reflects writes
- **WHEN** a caller writes `viking://resources/p/docs/a.md` and `viking://resources/p/docs/b.md` then lists `viking://resources/p/docs`
- **THEN** the listing includes both `a.md` and `b.md`

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
The store SHALL apply every write to SQLite before acknowledging it, and SHALL NOT allow any ETS cache to serve content newer than SQLite state (no cache-ahead-of-disk). Cache state after a write SHALL equal the state a cold cache would produce from SQLite.

#### Scenario: Cache matches disk after write
- **WHEN** a caller writes a document and immediately reads it through the cached path
- **THEN** the read returns the same content as a read through the SQLite fallback path

### Requirement: Keyword search
The store SHALL provide case-insensitive substring keyword search over document content and summaries, optionally scoped to a subtree URI prefix, returning matching URIs with their matched document data. The store SHALL ALSO provide vector similarity search (see `vector-search` capability) and hybrid search combining both signals.

#### Scenario: Search scoped to subtree
- **WHEN** documents exist under `viking://resources/p/` containing the term "nif" and elsewhere not containing it
- **THEN** searching "NIF" scoped to `viking://resources/p/` returns only URIs under that prefix

#### Scenario: Case-insensitive match
- **WHEN** a document contains "SQLite" and the caller searches "sqlite"
- **THEN** the document URI is returned

#### Scenario: Vector search mode
- **WHEN** caller searches with `mode: :vector` and query "machine learning"
- **THEN** results are ranked by cosine similarity to query embedding
- **AND** each result includes similarity score

#### Scenario: Hybrid search mode
- **WHEN** caller searches with `mode: :hybrid`
- **THEN** results combine keyword and vector scores via reciprocal rank fusion
- **AND** ranking reflects both exact matches and semantic similarity

### Requirement: Sessions with commit-to-context
The store SHALL record sessions as append-only, ordered message lists persisted in SQLite, and SHALL support committing a session into the context tree at a caller-chosen destination URI as a single document whose content is derived from the session's messages in order. Commit SHALL be idempotent per (session, destination) pair: re-committing without new messages SHALL not duplicate content.

#### Scenario: Append and commit a session
- **WHEN** messages are appended to a session and the session is committed to `viking://user/u1/memories/session-42`
- **THEN** a document exists at that URI containing all messages in order, and re-committing the unchanged session leaves exactly one such document

### Requirement: Durable restart recovery
The store SHALL recover the full context tree, sessions, and search capability from SQLite alone after a full process restart, with ETS caches rebuilt lazily on demand.

#### Scenario: Survive restart
- **WHEN** documents and a session are written, the application is stopped and restarted, and the same URIs are read again
- **THEN** all reads return identical content and search still matches the pre-restart documents

### Requirement: Pure offline operation
The store SHALL perform all core operations locally with no mandatory external dependencies. Embedding models and LLMs SHALL run locally on the host machine (CPU or GPU) with weights cached on disk. Network requests SHALL only occur for optional model downloads on first use, and for the optional WebSocket API (see `http-api` capability) when enabled. The store SHALL function fully without network connectivity once models are cached.

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

### Requirement: Async write acknowledgement
The store SHALL acknowledge writes (`write/3`) immediately after persisting to SQLite, before embedding generation and LLM summarization complete. Background jobs SHALL process embedding and summarization asynchronously. Readers SHALL see progressively enhanced content: content (L2) immediately, then abstract/overview (L0/L1) once generated, then vector searchability once embedded.

#### Scenario: Write returns before embeddings ready
- **WHEN** a caller writes a document
- **THEN** `:ok` is returned immediately
- **AND** `read/1` returns content immediately
- **AND** `abstract/1` and `overview/1` return fallback or generated content when ready
- **AND** `search/2` with `mode: :vector` includes the document once embedding is indexed

### Requirement: Background job processing
The store SHALL maintain a durable job queue (SQLite-backed) for embedding generation and summarization tasks. Jobs SHALL be processed by a background worker pool. Job processing SHALL survive restarts: pending jobs SHALL resume after restart. Failed jobs SHALL be retried with exponential backoff.

#### Scenario: Jobs survive restart
- **WHEN** documents are written, generating pending embedding/summarization jobs
- **AND** application restarts
- **THEN** pending jobs resume processing after restart
- **AND** no jobs are lost

#### Scenario: Failed jobs retry
- **WHEN** an embedding job fails with transient error
- **THEN** job is re-queued with exponential backoff
- **AND** other jobs continue processing

### Requirement: Configuration for models and async behavior
The store SHALL be configurable for: embedding model name/URL, LLM model name/URL, CPU/GPU backend, async vs sync write mode, job worker pool size, model cache directory, HTTP API enablement and port.

#### Scenario: Configurable async mode
- **WHEN** configured with `async_writes: false`
- **THEN** `write/3` blocks until embedding and summarization complete
- **WHEN** configured with `async_writes: true` (default)
- **THEN** `write/3` returns immediately
