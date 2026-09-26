# Spec Delta

## MODIFIED Requirements

### Requirement: Background job processing
The store SHALL maintain a durable job queue (SQLite-backed) for embedding generation and summarization tasks. Jobs SHALL be processed by a background worker pool. Job processing SHALL survive restarts: pending jobs SHALL resume after restart. Failed jobs SHALL be retried with exponential backoff. The retry budget SHALL be reserved for work that can succeed on retry: a job deferred because a model is still loading SHALL be rescheduled without consuming an attempt. A deferred job SHALL remain distinguishable from a completed one and from a failed one.

#### Scenario: Jobs survive restart
- **WHEN** documents are written, generating pending embedding/summarization jobs
- **AND** application restarts
- **THEN** pending jobs resume processing after restart
- **AND** no jobs are lost

#### Scenario: Failed jobs retry
- **WHEN** an embedding job fails with transient error
- **THEN** job is re-queued with exponential backoff
- **AND** other jobs continue processing

#### Scenario: Deferring for an unloaded model does not consume the retry budget
- **WHEN** a job is deferred because its model is still loading, repeatedly
- **THEN** the job is rescheduled and remains eligible
- **AND** its attempt count is not advanced by the deferrals
- **AND** it is not marked failed

#### Scenario: A failed job is distinguishable from a deferred one
- **WHEN** a job has exhausted its attempts and is marked failed
- **AND** another job is deferred because a model is loading
- **THEN** the two jobs are reported as different states

### Requirement: Async write acknowledgement
The store SHALL acknowledge writes (`write/3`) immediately after persisting to SQLite, before embedding generation and LLM summarization complete. Background jobs SHALL process embedding and summarization asynchronously. Readers SHALL see progressively enhanced content: content (L2) immediately, then abstract/overview (L0/L1) once generated, then vector searchability once embedded. A caller that has asked for the work to be completed before the write returns SHALL be told which of the three outcomes occurred: the work completed, the work failed, or the work is still outstanding. A failed job SHALL NOT be reported to a synchronous caller as though the work had completed.

#### Scenario: Write returns before embeddings ready
- **WHEN** a caller writes a document
- **THEN** `:ok` is returned immediately
- **AND** `read/1` returns content immediately
- **AND** `abstract/1` and `overview/1` return fallback or generated content when ready
- **AND** `search/2` with `mode: :vector` includes the document once embedding is indexed

#### Scenario: Synchronous write reports completion honestly
- **WHEN** a caller writes with `async: false` and the background jobs complete
- **THEN** `write/3` returns `:ok`

#### Scenario: Synchronous write reports failure rather than success
- **WHEN** a caller writes with `async: false` and the background jobs for that document fail
- **THEN** `write/3` returns an error
- **AND** it does not report success as though the work had completed

#### Scenario: Synchronous write reports work still outstanding
- **WHEN** a caller writes with `async: false` and the background jobs have not finished within the wait
- **THEN** `write/3` reports that the work is still outstanding
- **AND** it does not report success

### Requirement: Configuration for models and async behavior
The store SHALL be configurable for: embedding model name/URL, LLM model name/URL, CPU/GPU backend, async vs sync write mode, job worker pool size, model cache directory, HTTP API enablement and port, and the wait applied to a model-dependent request that is made while the model is still loading. A configured CPU/GPU backend SHALL take effect: the models the store loads SHALL be placed on the configured backend rather than on a default chosen independently of that configuration. The configured wait SHALL be honoured, and a caller SHALL never be blocked indefinitely on a model that is still loading.

#### Scenario: Configurable async mode
- **WHEN** configured with `async_writes: false`
- **THEN** `write/3` blocks until embedding and summarization complete
- **WHEN** configured with `async_writes: true` (default)
- **THEN** `write/3` returns immediately

#### Scenario: Configured backend takes effect
- **WHEN** a CPU/GPU backend is configured
- **THEN** both the embedding model and the summarization model are loaded onto that backend
- **AND** the configured value is not read and discarded

#### Scenario: The wait for a loading model is configurable
- **WHEN** a wait is configured for model-dependent requests
- **THEN** a request made while the model is loading waits no longer than that
- **AND** a longer or shorter wait changes how long the caller is held, not whether the model eventually loads
