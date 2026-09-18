## MODIFIED Requirements

### Requirement: Embedding model management
The store SHALL download and cache the configured embedding model on first startup if not present locally. Model loading SHALL be lazy (on first embedding request) or eager (at startup, configurable). The model SHALL run entirely locally using the configured ML backend (EXLA or EMLX). The model SHALL run on CPU by default, or on Apple Silicon GPU/Neural Engine via MLX when EMLX backend is selected.

#### Scenario: Model downloads on first use
- **WHEN** system starts with no cached model and embedding is requested
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent requests use cached model

#### Scenario: Model runs on CPU by default
- **WHEN** no GPU configuration is provided
- **THEN** embeddings are generated using CPU backend
- **AND** generation completes within acceptable latency (e.g., <500ms for 384-dim)

#### Scenario: Model runs on Apple Silicon via MLX when EMLX backend selected
- **WHEN** `ml_backend` is `:emlx` or `:auto` on Apple Silicon macOS
- **THEN** embeddings are generated using MLX backend
- **AND** generation completes with lower latency than CPU baseline

#### Scenario: Backend falls back to EXLA on EMLX failure
- **WHEN** `ml_backend` is `:emlx` or `:auto` on macOS but EMLX fails to load
- **THEN** a warning is logged
- **AND** the embedding model loads via EXLA CPU backend instead
- **AND** embedding generation continues to function