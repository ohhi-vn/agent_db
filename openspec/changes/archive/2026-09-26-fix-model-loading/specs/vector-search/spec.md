# Spec Delta

## MODIFIED Requirements

### Requirement: Vector embeddings generated for all documents
The store SHALL generate a vector embedding for every document's content (L2) using a configured local embedding model. Embeddings SHALL be stored in a sqlite-vec virtual table with HNSW index for efficient similarity search. When a document is written, its embedding SHALL be generated asynchronously and the vector index updated without blocking the write acknowledgement. Loading the configured model SHALL succeed when its weights are present in the local cache, and a successful load SHALL be observable: the loaded model SHALL be retained and reused for subsequent embedding requests rather than reloaded per request. A load that fails SHALL report an error identifying the failure, and SHALL NOT be reported as a successful load.

#### Scenario: Write triggers async embedding generation
- **WHEN** a caller writes a document with content
- **THEN** the write returns `:ok` immediately
- **AND** a background job is enqueued to generate the embedding
- **AND** once complete, the embedding is queryable via vector search

#### Scenario: Embedding uses configured model
- **WHEN** the system starts with embedding model `all-MiniLM-L6-v2`
- **THEN** all generated embeddings are 384-dimensional
- **AND** the same model produces consistent embeddings for identical content

#### Scenario: Cached model loads successfully
- **WHEN** the configured embedding model is present in the local cache and an embedding is requested
- **THEN** the model loads successfully and the request proceeds to inference rather than failing at load
- **AND** the loaded model is retained so that a second embedding request does not reload it

#### Scenario: A failed load is reported, not silently substituted
- **WHEN** loading the embedding model fails
- **THEN** the request reports an error naming the cause
- **AND** no embedding is written to the vector index for that request

### Requirement: Embedding model management
The store SHALL download and cache the configured embedding model on first startup if not present locally. Model loading SHALL be lazy (on first embedding request) or eager (at startup, configurable). The model SHALL run entirely locally using EXLA/Bumblebee with CPU or GPU backend. A configured backend SHALL be applied to the loaded model, so that the selection takes effect rather than being read and discarded. A download SHALL be written atomically: partial content SHALL NOT be left at the model's final path, and a file at that path SHALL be treated as complete only if the download finished. A download that fails or is interrupted SHALL leave no file that later requests treat as a usable cached model.

#### Scenario: Model downloads on first use
- **WHEN** system starts with no cached model and embedding is requested
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent requests use cached model

#### Scenario: Model runs on CPU by default
- **WHEN** no GPU configuration is provided
- **THEN** embeddings are generated using CPU backend
- **AND** generation completes within acceptable latency (e.g., <500ms for 384-dim)

#### Scenario: Configured backend is applied
- **WHEN** a compute backend is configured
- **THEN** the loaded model is placed on that backend
- **AND** the configuration is not silently ignored

#### Scenario: Interrupted download does not poison the cache
- **WHEN** a model download fails partway through
- **THEN** no file is left at the model's cache path
- **AND** a later request retries the download rather than failing against a truncated file
