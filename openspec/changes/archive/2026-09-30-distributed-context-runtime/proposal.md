# Proposal

## Why

AgentDb is already an embedded offline `viking://` context tree with L0/L1/L2 layers, vector search, memory, and skills. The opportunity is not to clone OpenViking feature-for-feature, but to make the system feel native to OTP, Phoenix, and BEAM distribution: a distributed context runtime for AI agents where supervision, reactivity, Elixir structure-awareness, and live runtime inspection are first-class.

## What Changes

- Add reactive context subscriptions: `AgentDb.subscribe/1`, `unsubscribe/1`, and `{:context_changed, uri, version}` events over the existing `AgentDb.PubSub`, covering writes, removals, and session commits.
- Add Elixir structural code indexing: parse project sources with `Code.string_to_quoted/2` into Module/function/macro/behaviour/protocol/struct/alias/callers relations stored as context, queryable without an LLM.
- Add Hex-aware docs context: ingest README/HexDocs/API for installed Hex packages with installed-version prioritization from `mix.lock`, preventing version-incompatible retrieval.
- Add read-only BEAM runtime context: snapshot nodes/applications/supervisors/processes/ETS/telemetry/crashes as queryable context for live diagnosis.
- Formalize pluggable inference and storage behind the existing `AgentDb.Runtime` ports: `Embedder`/`Summarizer` behaviours with local Nx/Bumblebee/EXLA default plus Ollama/OpenAI-compatible adapters; storage port stays SQLite-by-default with a documented path for Postgres/pgvector adapters.
- Extend Phoenix Channel with retrieval-progress streaming (`retrieval started/progress/resource found/skill loaded/context ready`) and subscription fan-out.
- Extend OpenTelemetry to per-stage retrieval spans (intent, resource/memory/skill search, embedding, rerank, assembly) with existing bounded-dimension and redaction invariants preserved.
- Add `mix agent_db.index`, `mix agent_db.search`, `mix agent_db.tree`, `mix agent_db.doctor` alongside the existing `mix agent_db.import_skills`.
- Explicitly defer full cluster distribution (libcluster/Horde/CRDT global search, agent-to-agent sharing) to a follow-up change; this change adds only the local primitives (subscriptions, provider ports, versioned events) that make distribution possible later.

## Capabilities

### New Capabilities

- `context-subscriptions`: reactive subscribe/watch/notify for `viking://` URIs over Phoenix.PubSub with versioning and removal semantics.
- `elixir-code-index`: structural Elixir source indexing and OTP-aware retrieval (supervision relations, GenServer callbacks, callers/callees).
- `hex-docs-context`: Hex ecosystem docs ingestion with installed-version-aware ranking.
- `beam-runtime-context`: live BEAM inspection snapshots exposed as read-only context.
- `inference-providers`: pluggable embedding/summarization provider behaviours with local-first default.

### Modified Capabilities

- `http-api`: streaming retrieval progress events and subscription delivery over the versioned `v1.*` channel API.
- `runtime-observability`: per-stage retrieval spans and progress measurements under existing bounded-dimension and no-content-in-logs rules.
- `vector-search`: allow embeddings from a configured provider (local by default) instead of mandating a local model in every deployment.
- `llm-summarization`: allow summaries from a configured provider (local by default) instead of mandating a local LLM in every deployment.

## Impact

- Affected code: `AgentDb` public API, `AgentDb.Application` supervision tree, `AgentDb.Runtime` ports, `Core.Storage`/`Core.Inference` behaviours, Phoenix Channel/WebSocket layer, Mix tasks, telemetry/OTel spans.
- APIs: additive `subscribe/unsubscribe`, progress events, provider configs (`config :agent_db, embedding: ...`); no changes to existing `read/write/search/find/grep` contracts except provider source.
- Dependencies: no new mandatory runtime deps; optional adapters (Ollama/HTTP, Postgres/pgvector) remain opt-in to preserve fully-local install (`{:agent_db, "~> 0.1"}` with ETS/Mnesia/SQLite only).
- Systems: preserves SQLite-as-source-of-truth, ETS-disposable-cache, durable JobQueue, offline-first, and removal-completeness invariants; cluster distribution explicitly out of scope.
