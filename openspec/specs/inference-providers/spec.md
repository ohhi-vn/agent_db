# inference-providers Specification

## Purpose
Decouples what the store needs (embeddings, summaries) from how they are produced, so deployments can keep the local default or plug in Ollama and OpenAI-compatible providers without changing call contracts.

## Requirements

### Requirement: Provider behaviours for inference
The system SHALL define `Embedder` and `Summarizer` provider behaviours behind the existing `AgentDb.Runtime` inference port: `embed/1` returning comparable stable float32 vectors per input, and `summarize/2` returning non-empty text or an error. A configured provider that is missing or incomplete SHALL fail startup validation rather than silently falling back to a different provider. Switching providers SHALL NOT change `AgentDb` function signatures or `search/find/grep` result shapes apart from the values produced by inference.

#### Scenario: Custom provider serves embeddings
- **WHEN** a deployment configures a custom embedder returning stable 384-dim vectors
- **THEN** writes become vector-searchable through that provider with no change to `search/2` options

#### Scenario: Incomplete provider fails fast at startup
- **WHEN** a configured provider module does not implement the required callbacks
- **THEN** application startup raises identifying the missing callbacks
- **AND** the store does not silently serve from the default instead

### Requirement: Local-first default with no mandatory network
With no provider configured the system SHALL behave exactly as today: local Nx/Bumblebee models via EXLA (or EMLX on Apple Silicon), 384-dim embeddings stable per input, no network except first-use model download, and `:model_loading` distinctly reported from failure. Installing `{:agent_db, "~> 0.1"}` with no extra config SHALL require no Docker, vector service, or remote key.

#### Scenario: Default install stays fully local
- **WHEN** the store runs with default config and cached models
- **THEN** embedding and summarization complete with no network requests
- **AND** a fresh install documents only a local model download on first use

### Requirement: Remote adapters map failures to existing contracts
HTTP-based adapters (Ollama, OpenAI-compatible) SHALL map timeouts, auth failures, and rate limits onto the store's existing error contracts: still-loading stays `{:error, :model_loading}` and retryable, other inference failures return classified `{:error, reason}` without terminating the caller or connection, and deferred background jobs reschedule without consuming retry attempts. Adapter credentials SHALL come only from configuration or environment and SHALL never appear in logs, traces, or error payloads. OpenAI-compatible requests SHALL include the configured `model` in `/embeddings` and `/chat/completions` bodies. Ollama embed requests SHALL batch inputs instead of issuing one POST per text, with per-text fallback when the server rejects a batch.

#### Scenario: Remote timeout does not terminate the caller
- **WHEN** an Ollama embed request times out
- **THEN** the caller receives `{:error, {:inference_timeout, _}}`
- **AND** the calling process and any channel connection remain usable

#### Scenario: Credentials never leak
- **WHEN** a remote provider is configured with an API key and a request fails
- **THEN** logs, telemetry, and error responses omit the key and any secret query params

#### Scenario: OpenAI-compatible request carries its model
- **WHEN** the OpenAI-compatible provider embeds or summarizes with a configured model
- **THEN** the HTTP body names that model
- **AND** a server requiring `model` no longer rejects with 400

#### Scenario: Ollama embeds batch inputs
- **WHEN** multiple texts are embedded via Ollama
- **THEN** they are sent as one batched `/api/embed` call rather than one POST per text
- **AND** per-text results preserve input order

### Requirement: Provider-aware model status
`model_status/0` SHALL report the active provider kind (`local | ollama | openai_compatible | custom`), per-model state (`loading | ready | failed | idle`), dimensionality for embeddings, and queue depth, while remaining answerable during downloads and loads. The reported parameter size and dimensionality SHALL reflect the active provider rather than a fixed value. The reported provider kind SHALL be the provider that actually serves inference, not a separately configured label. The reported queue depth SHALL reflect the durable background-job queue rather than a fixed value. For remote providers, status SHALL distinguish an unreachable provider from a ready one. Embedding dimensionality SHALL be the last observed vector dim, or `:unknown` before any successful embed; hardcoded dims SHALL NOT be reported as observed. A remotely ready provider SHALL count as healthy in `health()` even though no local model is loaded.

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

#### Scenario: Fresh boot reports unknown dim until first embed
- **WHEN** no embedding has succeeded since boot
- **THEN** `model_status()` reports embedding dim as `:unknown`
- **AND** it does not report a hardcoded dim as observed

#### Scenario: Healthy remote counts as healthy store
- **WHEN** the active provider is remote and reachable
- **THEN** `health()` reports models as ready
- **AND** the store is not reported `degraded` solely for holding no local model

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
