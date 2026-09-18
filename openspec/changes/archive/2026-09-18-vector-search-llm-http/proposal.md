## Why

AI agents need semantic recall over their context — finding relevant memories by meaning, not just keyword matching. The current `context-store` provides keyword search and caller-supplied summaries, but lacks vector embeddings, automatic LLM summarization, and a network API for remote agents. This change adds all three while keeping SQLite as the source of truth and preserving offline-first operation.

## What Changes

- **New**: Vector search via `sqlite-vec` extension (HNSW index on 384-dim embeddings)
- **New**: Automatic LLM summarization (L0 abstract + L1 overview) on document write
- **New**: Background job processor for async embedding/summarization (non-blocking writes)
- **New**: PhoenixGenApi WebSocket gateway for remote access (search, CRUD, sessions, model status)
- **New**: Model manager — downloads/caches `all-MiniLM-L6-v2` + `Phi-3-mini-4k-instruct` at startup
- **Modified**: `context-store` capability — relax "pure offline" requirement; add vector search, auto-summarization, and HTTP API requirements
- **BREAKING**: `AgentDb.write/3` returns immediately; embeddings/summaries appear eventually (async)
- **BREAKING**: New dependencies — `exla`, `bumblebee`, `nx`, `phoenix`, `phoenix_gen_api`, `oban` (or custom SQLite queue)

## Capabilities

### New Capabilities

- `vector-search`: Embedding generation, sqlite-vec index, hybrid (keyword + vector) search API
- `llm-summarization`: Automatic L0/L1 generation via local LLM, fallback to caller-supplied
- `http-api`: PhoenixGenApi WebSocket gateway exposing all store operations remotely

### Modified Capabilities

- `context-store`: 
  - Requirement "Pure offline operation" → relaxed to "local-first: models run locally, HTTP optional"
  - New requirement: "Vector search returns semantically similar documents"
  - New requirement: "Documents receive automatic LLM-generated summaries unless caller supplies them"
  - New requirement: "All operations available via WebSocket API"

## Impact

| Area | Change |
|------|--------|
| `AgentDb.write/3` | Returns `:ok` immediately; enqueues background job |
| `AgentDb.search/2` | Adds `mode: :vector \| :hybrid \| :keyword` option |
| `AgentDb.abstract/1`, `overview/1` | May return LLM-generated content if caller didn't supply |
| Dependencies | + `exla`, `bumblebee`, `nx`, `phoenix`, `phoenix_gen_api`, `oban` |
| Supervision tree | + `ModelManager`, `EmbeddingJobProcessor`, `PhoenixGenApi.Gateway` |
| Database | + `vec_nodes` virtual table (sqlite-vec), job queue table |
| Config | Model paths, download URLs, GPU/CPU backend, HTTP port |
| Tests | Need model fixtures, async job testing, WebSocket contract tests |