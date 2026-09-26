# Spec Delta

## MODIFIED Requirements

### Requirement: LLM model management
The store SHALL download and cache the configured summarization LLM (e.g., Phi-3-mini-4k-instruct) on first use. The model SHALL run entirely locally via Bumblebee/EXLA. Model loading SHALL be lazy or eager (configurable). Inference SHALL use appropriate quantization (e.g., q4) for memory efficiency. A configured backend SHALL be applied to the loaded model. A cached model SHALL load successfully and be retained for reuse. A download SHALL be written atomically, and a failed or interrupted download SHALL leave no file that later requests treat as a usable cached model. Because loading is lazy, a summary requested while the model is still loading SHALL be reported as loading and SHALL NOT be reported as a failure, and the caller SHALL be able to retry it. A request made while loading SHALL be given a bounded opportunity to complete before it is reported as loading, so that a request against an already-cached model does not have to be retried.

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

### Requirement: Summarization idempotency and retry
If a summarization job fails (model error, timeout, OOM), it SHALL be retried with exponential backoff. Re-processing the same document content SHALL produce deterministic output (same prompt, same model, same parameters = same result). Failed jobs SHALL not block other summarization work. The retry budget SHALL be reserved for failures that can succeed on retry: a job deferred because its model is still loading SHALL NOT consume an attempt, and SHALL be rescheduled rather than counted toward exhaustion.

#### Scenario: Failed summarization retries
- **WHEN** a summarization job fails with transient error
- **THEN** job is re-queued with backoff
- **AND** other summarization jobs continue processing

#### Scenario: Same content produces same summary
- **WHEN** two documents with identical content are written at different times
- **THEN** their auto-generated abstracts and overviews are identical

#### Scenario: Waiting for a model does not exhaust the retry budget
- **WHEN** a summarization job is deferred repeatedly because the model is still loading
- **THEN** the job remains eligible for processing and is not marked failed
- **AND** its retry attempts are not consumed by the deferrals
- **AND** the job completes once the model is loaded
