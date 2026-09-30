# Spec Delta

## Purpose

Decouples what the store needs (embeddings, summaries) from how they are produced, so deployments can keep the local default or plug in Ollama and OpenAI-compatible providers without changing call contracts.

## ADDED Requirements

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
HTTP-based adapters (Ollama, OpenAI-compatible) SHALL map timeouts, auth failures, and rate limits onto the store's existing error contracts: still-loading stays `{:error, :model_loading}` and retryable, other inference failures return classified `{:error, reason}` without terminating the caller or connection, and deferred background jobs reschedule without consuming retry attempts. Adapter credentials SHALL come only from configuration or environment and SHALL never appear in logs, traces, or error payloads.

#### Scenario: Remote timeout does not terminate the caller
- **WHEN** an Ollama embed request times out
- **THEN** the caller receives `{:error, {:inference_timeout, _}}`
- **AND** the calling process and any channel connection remain usable

#### Scenario: Credentials never leak
- **WHEN** a remote provider is configured with an API key and a request fails
- **THEN** logs, telemetry, and error responses omit the key and any secret query params

### Requirement: Provider-aware model status
`model_status/0` SHALL report the active provider kind (`local | ollama | openai_compatible | custom`), per-model state (`loading | ready | failed | idle`), dimensionality for embeddings, and queue depth, while remaining answerable during downloads and loads. The reported parameter size and dimensionality SHALL reflect the active provider rather than a fixed value.

#### Scenario: Status reflects the active provider
- **WHEN** the embedder is Ollama and the summarizer is local
- **THEN** `model_status()` names each provider kind and reports each state independently
- **AND** a load in progress is reported as loading rather than as unloaded
