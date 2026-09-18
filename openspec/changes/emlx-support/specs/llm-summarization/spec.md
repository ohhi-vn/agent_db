## MODIFIED Requirements

### Requirement: LLM model management
The store SHALL download and cache the configured summarization LLM (e.g., Phi-3-mini-4k-instruct) on first use. The model SHALL run entirely locally via the configured ML backend (EXLA or EMLX/EMLXAxon). Model loading SHALL be lazy or eager (configurable). Inference SHALL use appropriate quantization (e.g., q4) for memory efficiency. When the configured backend is unavailable or fails to initialize, the system SHALL fall back to EXLA CPU with a warning logged.

#### Scenario: Summarization model downloads on first use
- **WHEN** system starts with no cached LLM and summarization is needed
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent summarization uses cached model

#### Scenario: Summarization completes within acceptable latency
- **WHEN** LLM generates abstract/overview for typical document (<2000 tokens)
- **THEN** generation completes within configured timeout (e.g., <5s on CPU)

#### Scenario: Backend falls back to EXLA on EMLX failure
- **WHEN** `ml_backend` is `:emlx` or `:auto` on macOS but EMLX/EMLXAxon fails to load
- **THEN** a warning is logged
- **AND** the LLM loads via EXLA CPU backend instead
- **AND** summarization continues to function