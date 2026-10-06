# Spec Delta

## MODIFIED Requirements

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
