## MODIFIED Requirements

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

## ADDED Requirements

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