# vector-search Specification

## Purpose
Provides semantic vector search over stored documents using locally-run embedding models, with results fused with keyword search for hybrid retrieval.

## Requirements

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
### Requirement: Vector similarity search
The store SHALL provide a vector search operation that accepts a query text, generates its embedding, and returns the top-k most similar documents by cosine similarity. Results SHALL include the document URI, content, abstract, overview, and similarity score. A search issued while the embedding model is still loading SHALL report that the model is loading, and SHALL NOT be reported as though the query itself were invalid or the capability permanently unavailable.

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

#### Scenario: Searching while the model loads is reported as loading
- **WHEN** a vector search is issued and the embedding model is still loading
- **THEN** the search reports that the model is loading
- **AND** the same search succeeds once the model is loaded
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
The store SHALL download and cache the configured embedding model on first startup if not present locally. Model loading SHALL be lazy (on first embedding request) or eager (at startup, configurable). The model SHALL run entirely locally using the configured ML backend (EXLA or EMLX). The model SHALL run on CPU by default, or on Apple Silicon GPU/Neural Engine via MLX when EMLX backend is selected. A configured backend SHALL be applied to the loaded model, so that the selection takes effect rather than being read and discarded. When the configured backend is unavailable or fails to initialize, the system SHALL fall back to EXLA CPU with a warning logged. A download SHALL be written atomically: partial content SHALL NOT be left at the model's final path, and a file at that path SHALL be treated as complete only if the download finished. A download that fails or is interrupted SHALL leave no file that later requests treat as a usable cached model. Because loading is lazy, an embedding requested while the model is still loading SHALL be reported as loading and SHALL NOT be reported as a failure, and the caller SHALL be able to retry it. A request made while loading SHALL be given a bounded opportunity to complete before it is reported as loading. Loading SHALL NOT block the store from answering questions about its own state. The embedding model SHALL reach a loaded state once its own load completes, including when another model is loading concurrently: beginning a load for one model SHALL NOT leave the embedding model reporting as loading indefinitely.

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

#### Scenario: An embedding requested while loading is reported as loading
- **WHEN** an embedding is requested and the model is not yet loaded and a load is in progress
- **THEN** the request reports that the model is loading
- **AND** the request is not reported as a failure
- **AND** a later request, once the model is loaded, produces an embedding

#### Scenario: A cached model does not force the caller to retry
- **WHEN** an embedding is requested, the weights are already cached, and the load completes within the configured wait
- **THEN** the original request produces an embedding
- **AND** the caller is not told to retry

#### Scenario: The store stays responsive while a model loads
- **WHEN** a model is being loaded
- **THEN** a request for the store's model status is answered
- **AND** it reports that the model is not yet loaded

#### Scenario: The embedding model loads while another model is loading
- **WHEN** an embedding is requested and a load for another model is already in progress
- **THEN** the embedding model's own load proceeds independently
- **AND** the embedding model reaches a loaded state rather than continuing to report as loading
- **AND** a later embedding request proceeds to inference instead of reporting the model as still loading

#### Scenario: Model runs on Apple Silicon via MLX when EMLX backend selected
- **WHEN** `ml_backend` is `:emlx` or `:auto` on Apple Silicon macOS
- **THEN** embeddings are generated using MLX backend
- **AND** generation completes with lower latency than CPU baseline

#### Scenario: Backend falls back to EXLA on EMLX failure
- **WHEN** `ml_backend` is `:emlx` or `:auto` on macOS but EMLX fails to load
- **THEN** a warning is logged
- **AND** the embedding model loads via EXLA CPU backend instead
- **AND** embedding generation continues to function
### Requirement: Vector index persistence and recovery
The sqlite-vec virtual table and HNSW index SHALL persist across restarts. After restart, vector search SHALL be immediately available without re-embedding all documents.

#### Scenario: Vector index survives restart
- **WHEN** documents with embeddings exist, application restarts
- **THEN** vector search returns results without re-processing documents
- **AND** index state matches pre-restart state
