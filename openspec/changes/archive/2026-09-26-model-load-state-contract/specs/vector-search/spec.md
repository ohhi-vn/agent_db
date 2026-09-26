# Spec Delta

## MODIFIED Requirements

### Requirement: Embedding model management
The store SHALL download and cache the configured embedding model on first startup if not present locally. Model loading SHALL be lazy (on first embedding request) or eager (at startup, configurable). The model SHALL run entirely locally using EXLA/Bumblebee with CPU or GPU backend. A configured backend SHALL be applied to the loaded model, so that the selection takes effect rather than being read and discarded. A download SHALL be written atomically: partial content SHALL NOT be left at the model's final path, and a file at that path SHALL be treated as complete only if the download finished. A download that fails or is interrupted SHALL leave no file that later requests treat as a usable cached model. Because loading is lazy, an embedding requested while the model is still loading SHALL be reported as loading and SHALL NOT be reported as a failure, and the caller SHALL be able to retry it. A request made while loading SHALL be given a bounded opportunity to complete before it is reported as loading. Loading SHALL NOT block the store from answering questions about its own state.

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
