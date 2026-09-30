## MODIFIED Requirements

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
