# Spec Delta

## MODIFIED Requirements

### Requirement: LLM model management
The store SHALL download and cache the configured summarization LLM (e.g., Phi-3-mini-4k-instruct) on first use. The model SHALL run entirely locally via Bumblebee/EXLA. Model loading SHALL be lazy or eager (configurable). Inference SHALL use appropriate quantization (e.g., q4) for memory efficiency. A configured backend SHALL be applied to the loaded model. A cached model SHALL load successfully and be retained for reuse. A download SHALL be written atomically, and a failed or interrupted download SHALL leave no file that later requests treat as a usable cached model.

#### Scenario: Summarization model downloads on first use
- **WHEN** system starts with no cached LLM and summarization is needed
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent summarization uses cached model

#### Scenario: Summarization completes within acceptable latency
- **WHEN** LLM generates abstract/overview for typical document (<2000 tokens)
- **THEN** generation completes within configured timeout (e.g., <5s on CPU)

#### Scenario: Cached summarization model loads successfully
- **WHEN** the configured LLM is present in the local cache and a summary is requested
- **THEN** the model loads successfully and the request proceeds to inference rather than failing at load
- **AND** the loaded model is retained so a second request does not reload it

#### Scenario: Configured backend is applied to the summarization model
- **WHEN** a compute backend is configured
- **THEN** the loaded summarization model is placed on that backend
- **AND** the configuration is not silently ignored

#### Scenario: Interrupted LLM download does not poison the cache
- **WHEN** the summarization model download fails partway through
- **THEN** no file is left at the model's cache path
- **AND** a later request retries the download rather than failing against a truncated file
