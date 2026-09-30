# Spec Delta

## MODIFIED Requirements

### Requirement: Vector embeddings generated for all documents
The store SHALL generate a vector embedding for every document's content (L2) using the configured embedding provider (local model by default, see `inference-providers` capability). Embeddings SHALL be stored in a sqlite-vec virtual table with HNSW index for efficient similarity search. When a document is written, its embedding SHALL be generated asynchronously and the vector index updated without blocking the write acknowledgement. Loading the configured model SHALL succeed when its weights are present in the local cache, and a successful load SHALL be observable: the loaded model SHALL be retained and reused for subsequent embedding requests rather than reloaded per request. A load that fails SHALL report an error identifying the failure, and SHALL NOT be reported as a successful load.

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

#### Scenario: Configured remote provider serves embeddings
- **WHEN** the embedder is configured to Ollama with a reachable endpoint
- **THEN** document writes become vector-searchable through that provider
- **AND** vector search results keep their existing URI, content, and score shape
