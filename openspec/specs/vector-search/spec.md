# vector-search Specification

## Purpose
Provides semantic vector search over stored documents using locally-run embedding models, with results fused with keyword search for hybrid retrieval.

## Requirements

### Requirement: Vector embeddings generated for all documents
The store SHALL generate a vector embedding for every document's content (L2) using a configured local embedding model. Embeddings SHALL be stored in a sqlite-vec virtual table with HNSW index for efficient similarity search. When a document is written, its embedding SHALL be generated asynchronously and the vector index updated without blocking the write acknowledgement.

#### Scenario: Write triggers async embedding generation
- **WHEN** a caller writes a document with content
- **THEN** the write returns `:ok` immediately
- **AND** a background job is enqueued to generate the embedding
- **AND** once complete, the embedding is queryable via vector search

#### Scenario: Embedding uses configured model
- **WHEN** the system starts with embedding model `all-MiniLM-L6-v2`
- **THEN** all generated embeddings are 384-dimensional
- **AND** the same model produces consistent embeddings for identical content

### Requirement: Vector similarity search
The store SHALL provide a vector search operation that accepts a query text, generates its embedding, and returns the top-k most similar documents by cosine similarity. Results SHALL include the document URI, content, abstract, overview, and similarity score.

#### Scenario: Vector search returns ranked results
- **WHEN** documents exist with embeddings and the caller searches "machine learning" with `mode: :vector`
- **THEN** results are ordered by cosine similarity descending
- **AND** each result includes a similarity score between -1 and 1
- **AND** the top result is semantically related to the query

#### Scenario: Vector search respects top-k limit
- **WHEN** caller requests `top_k: 3`
- **THEN** at most 3 results are returned

#### Scenario: Vector search scoped to subtree
- **WHEN** documents exist under `viking://resources/p/` and `viking://resources/q/` and caller searches with `scope: "viking://resources/p"` and `mode: :vector`
- **THEN** only results under the `viking://resources/p/` prefix are returned

### Requirement: Hybrid search (keyword + vector)
The store SHALL provide a hybrid search mode that combines keyword (BM25-like) and vector similarity scores using reciprocal rank fusion (RRF) or weighted combination, returning a single ranked result set.

#### Scenario: Hybrid search fuses both signals
- **WHEN** documents contain exact keyword matches and semantically similar content
- **THEN** hybrid search returns results ranking both exact matches and semantic neighbors
- **AND** results include both keyword match info and vector similarity score

#### Scenario: Hybrid search configurable weights
- **WHEN** caller specifies `hybrid_weights: [keyword: 0.5, vector: 0.5]`
- **THEN** the fusion uses those weights

### Requirement: Embedding model management
The store SHALL download and cache the configured embedding model on first startup if not present locally. Model loading SHALL be lazy (on first embedding request) or eager (at startup, configurable). The model SHALL run entirely locally using EXLA/Bumblebee with CPU or GPU backend.

#### Scenario: Model downloads on first use
- **WHEN** system starts with no cached model and embedding is requested
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent requests use cached model

#### Scenario: Model runs on CPU by default
- **WHEN** no GPU configuration is provided
- **THEN** embeddings are generated using CPU backend
- **AND** generation completes within acceptable latency (e.g., <500ms for 384-dim)

### Requirement: Vector index persistence and recovery
The sqlite-vec virtual table and HNSW index SHALL persist across restarts. After restart, vector search SHALL be immediately available without re-embedding all documents.

#### Scenario: Vector index survives restart
- **WHEN** documents with embeddings exist, application restarts
- **THEN** vector search returns results without re-processing documents
- **AND** index state matches pre-restart state
