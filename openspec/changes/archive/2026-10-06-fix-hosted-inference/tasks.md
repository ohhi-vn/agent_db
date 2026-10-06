# Tasks

## 1. Slice 1 — Remote request shapes

- [x] 1.1 Send `model` in OpenAI-compatible `/embeddings` and `/chat/completions` bodies (config/env-backed, default current literal) and verify provider-fake test asserting body carries model passes
- [x] 1.2 Batch Ollama `/api/embed` inputs with per-text fallback on server rejection and verify order-preserving batch test plus fallback test pass
- [x] 1.3 Run `mix test test/agent_db/adapters/inference_providers_test.exs` and verify green (credentials still redacted, timeouts classified)

## 2. Slice 1 — Health, status, weights compat

- [x] 2.1 Count remote `ready` as healthy in `health()` (not `loaded==true`) and verify healthy-Ollama reports `ok` while unreachable still reports degraded
- [x] 2.2 Report embedding dim as last-observed (`:unknown` before first embed), never hardcoded literals, and verify status test for fresh boot + post-embed dim passes
- [x] 2.3 Accept `hybrid_weights` as tuple and keyword list with identical fusion and verify both shapes produce same ranking in a fuse unit test

## 3. Slice 2 — Namespaced vector index + routing

- [x] 3.1 Create `vec_nodes_<dim>` lazily via `CREATE VIRTUAL TABLE IF NOT EXISTS` behind `vec_available?`, treating existing `vec_nodes` as 384, and verify `ensure_schema` idempotent across two calls
- [x] 3.2 Route `put_embedding_result`/`search_vector`/deletes by `byte_size(blob)/4` with dim-range guard + distinct-dim cap and verify mixed-dim writes land in separate tables
- [x] 3.3 Return `{:error, :dim_mismatch}` when query dim differs from active table (never cross-dim rank) and verify vector/hybrid legs surface it without exiting caller

## 4. Slice 2 — Backfill, prune, coverage

- [x] 4.1 Backfill only URIs missing in the active dim table via existing `:embed` queue and verify switching dims enqueues missing-only (no duplicates for covered URIs)
- [x] 4.2 Add explicit `prune(dim)` refusing the active dim (boot never wipes) and verify pruning non-active drops one table while pruning active is refused
- [x] 4.3 Report `{active_dim, vectors, documents, needs_backfill}` in `index_coverage`/`vector_index_stats` and verify partial backfill reports `needs_backfill: true`

## 5. Verification

- [x] 5.1 Run full `mix test` on a host with sqlite-vec loaded and verify vector/hybrid/dim-mismatch/backfill paths exercised (note: inert on hosts without the extension)
- [x] 5.2 Run `openspec validate --change fix-hosted-inference --strict` and verify zero errors
