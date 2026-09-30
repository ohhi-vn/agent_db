## MODIFIED Requirements

### Requirement: LLM model management
The store SHALL download and cache the configured summarization LLM (e.g., Qwen3-0.6B) on first use. The model SHALL run entirely locally via the configured ML backend (EXLA or EMLX/EMLXAxon). Model loading SHALL be lazy or eager (configurable). Inference SHALL use appropriate quantization (e.g., q4) for memory efficiency. A configured backend SHALL be applied to the loaded model. When the configured backend is unavailable or fails to initialize, the system SHALL fall back to EXLA CPU with a warning logged. A cached model SHALL load successfully and be retained for reuse. A download SHALL be written atomically, and a failed or interrupted download SHALL leave no file that later requests treat as a usable cached model. Because loading is lazy, a summary requested while the model is still loading SHALL be reported as loading and SHALL NOT be reported as a failure, and the caller SHALL be able to retry it. A request made while loading SHALL be given a bounded opportunity to complete before it is reported as loading, so that a request against an already-cached model does not have to be retried. The summarization model SHALL reach a loaded state once its own load completes, including when another model is loading concurrently: beginning a load for one model SHALL NOT leave the summarization model reporting as loading indefinitely. The format in which prompts are presented to the model SHALL be determined by configuration rather than fixed to one model architecture, so that configuring a different summarization model does not result in prompts being sent in a format that model was not built for. Generated summaries SHALL NOT contain the model's intermediate reasoning. A generation that yields no summary text once reasoning is removed SHALL be reported as an error and SHALL NOT be stored as an empty summary.

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

#### Scenario: A request made while the model is loading is reported as loading
- **WHEN** a summary is requested and the model is not yet loaded and a load is in progress
- **THEN** the request reports that the model is loading
- **AND** the request is not reported as a failure
- **AND** a later request, once the model is loaded, produces a summary

#### Scenario: A cached model does not force the caller to retry
- **WHEN** a summary is requested, the weights are already cached, and the load completes within the configured wait
- **THEN** the original request produces a summary
- **AND** the caller is not told to retry

#### Scenario: The summarization model loads while another model is loading
- **WHEN** a summary is requested and a load for another model is already in progress
- **THEN** the summarization model's own load proceeds independently
- **AND** the summarization model reaches a loaded state rather than continuing to report as loading
- **AND** a later summary request proceeds to inference instead of reporting the model as still loading

#### Scenario: The prompt format comes from configuration
- **WHEN** a summarization request is issued
- **THEN** the prompt is presented in the configured chat format
- **AND** the format used is not fixed to the architecture of any particular model

#### Scenario: A generated summary excludes the model's reasoning
- **WHEN** the model emits intermediate reasoning before its answer
- **THEN** the returned summary contains only the answer
- **AND** the stored abstract or overview does not contain the reasoning

#### Scenario: A generation with no answer after reasoning is reported as an error
- **WHEN** a generation produces reasoning but no summary text
- **THEN** the request reports an error rather than returning an empty summary
- **AND** no empty value is written to the document

#### Scenario: Backend falls back to EXLA on EMLX failure
- **WHEN** `ml_backend` is `:emlx` or `:auto` on macOS but EMLX/EMLXAxon fails to load
- **THEN** a warning is logged
- **AND** the LLM loads via EXLA CPU backend instead
- **AND** summarization continues to function
