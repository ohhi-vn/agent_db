# Spec Delta

## MODIFIED Requirements

### Requirement: Pure offline operation
The store SHALL perform all core operations locally with no mandatory external dependencies. Embedding models and LLMs SHALL run locally on the host machine (CPU or GPU) with weights cached on disk. Network requests SHALL only occur for optional model downloads on first use, and for the optional WebSocket API (see `http-api` capability) when enabled. The store SHALL function fully without network connectivity once models are cached. When a model is not cached and cannot be obtained, the affected operation SHALL report an error and SHALL NOT terminate the calling process, and SHALL NOT leave the store permanently unable to serve later requests.

#### Scenario: No network calls
- **WHEN** any store operation (write, read, search, session commit) runs
- **THEN** no network request is initiated

#### Scenario: No mandatory network calls
- **WHEN** models are cached and HTTP API is disabled
- **THEN** all store operations (write, read, search, session commit) complete without network requests

#### Scenario: Model download on first use
- **WHEN** system starts with no cached models and embedding/summarization is needed
- **THEN** models are downloaded from configured URLs to local cache
- **AND** subsequent operations use cached models without network

#### Scenario: Offline with uncached models reports an error
- **WHEN** a model is not cached and cannot be downloaded because the host is offline
- **THEN** the operation that needed it reports an error
- **AND** the calling process is not terminated
- **AND** store operations that do not require the model continue to succeed

#### Scenario: Unavailable model does not disable the store
- **WHEN** a model failed to load because it was unavailable
- **THEN** later requests that do not require that model are still served normally
- **AND** a later request retries the load rather than inheriting a permanently broken state

### Requirement: Configuration for models and async behavior
The store SHALL be configurable for: embedding model name/URL, LLM model name/URL, CPU/GPU backend, async vs sync write mode, job worker pool size, model cache directory, HTTP API enablement and port. A configured CPU/GPU backend SHALL take effect: the models the store loads SHALL be placed on the configured backend rather than on a default chosen independently of that configuration.

#### Scenario: Configurable async mode
- **WHEN** configured with `async_writes: false`
- **THEN** `write/3` blocks until embedding and summarization complete
- **WHEN** configured with `async_writes: true` (default)
- **THEN** `write/3` returns immediately

#### Scenario: Configured backend takes effect
- **WHEN** a CPU/GPU backend is configured
- **THEN** both the embedding model and the summarization model are loaded onto that backend
- **AND** the configured value is not read and discarded
