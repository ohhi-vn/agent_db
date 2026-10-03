# Spec Delta

## MODIFIED Requirements

### Requirement: Provider-aware model status
`model_status/0` SHALL report the active provider kind (`local | ollama | openai_compatible | custom`), per-model state (`loading | ready | failed | idle`), dimensionality for embeddings, and queue depth, while remaining answerable during downloads and loads. The reported parameter size and dimensionality SHALL reflect the active provider rather than a fixed value. The reported provider kind SHALL be the provider that actually serves inference, not a separately configured label. The reported queue depth SHALL reflect the durable background-job queue rather than a fixed value. For remote providers, status SHALL distinguish an unreachable provider from a ready one.

#### Scenario: Status reflects the active provider
- **WHEN** the embedder is Ollama and the summarizer is local
- **THEN** `model_status()` names each provider kind and reports each state independently
- **AND** a load in progress is reported as loading rather than as unloaded

#### Scenario: Provider status matches the serving provider
- **WHEN** a deployment configures a remote provider to serve inference
- **THEN** `model_status()` reports that provider kind
- **AND** it does not report the local provider while the remote provider is serving

#### Scenario: Queue depth is truthful
- **WHEN** durable background jobs are pending
- **THEN** `model_status()` reports a queue depth consistent with the durable job queue
- **AND** it does not report a hardcoded zero

#### Scenario: Unreachable remote provider is reported
- **WHEN** a configured remote provider is unreachable
- **THEN** `model_status()` reports the provider as unhealthy or unavailable rather than ready

## ADDED Requirements

### Requirement: Single authoritative provider selection
The system SHALL select the active inference provider from one authoritative configuration value. Setting that value SHALL change both the provider that serves inference and the provider kind reported by `model_status/0`, without requiring a second, separate key. A value that cannot be mapped to a known provider SHALL fail startup validation rather than silently serving from the default while reporting a different provider.

#### Scenario: One key switches serving and status together
- **WHEN** a deployment sets the documented provider configuration to a remote provider
- **THEN** both inference and `model_status()` use that provider
- **AND** no second configuration key is required to keep them consistent

#### Scenario: Unknown provider fails fast
- **WHEN** the configured provider value does not name a known provider
- **THEN** startup fails with an error identifying the invalid provider
- **AND** the store does not silently serve from the default while reporting a different provider
