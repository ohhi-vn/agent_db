# Spec Delta

## MODIFIED Requirements

### Requirement: Model status and health endpoints
The API SHALL expose endpoints for checking embedding model and LLM status: loaded/not loaded, memory usage, last inference latency, queue depth for background jobs. Model status SHALL remain answerable while a model is being downloaded or loaded, and SHALL report that a load is in progress rather than appearing simply unloaded. The parameter size reported for the summarization model SHALL reflect the configured model rather than a value fixed in the source, so that status output does not describe a model the store is not using.

#### Scenario: Model status query
- **WHEN** client calls `model_status()`
- **THEN** returns a map with `embedding`, `llm`, and `queue` entries
- **AND** the `embedding` entry reports whether the embedding model is loaded and its dimensionality
- **AND** the `llm` entry reports whether the summarization model is loaded and its parameter size

#### Scenario: Model status answers while a model is loading
- **WHEN** a model is being downloaded or loaded
- **THEN** `model_status()` returns a response rather than failing or hanging
- **AND** the response indicates that a load is in progress

#### Scenario: Reported model size follows configuration
- **WHEN** the configured summarization model differs from a previously reported one
- **THEN** `model_status()` reports the size of the currently configured model
- **AND** the reported size is not a fixed value that ignores the configuration
