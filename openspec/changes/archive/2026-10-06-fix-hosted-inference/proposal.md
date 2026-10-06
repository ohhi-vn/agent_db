# Proposal

## Why

Hosted inference (Ollama, OpenAI-compatible) is wired but not production-ready: missing `model` fields, N+1 embed calls, degraded health for healthy remotes, and silent vector corruption when provider dims differ (384 vs 768 vs 1536 in one `vec_nodes` table). Fix and finish the existing adapters so switching providers is safe and observable.

## What Changes

Slice 1 — safe bugfixes, no DDL:
- Send `model` in OpenAI-compatible `/embeddings` and `/chat/completions` bodies.
- Batch Ollama `/api/embed` input instead of one POST per text (keep per-text fallback if server rejects batch).
- Remote `ready` counts as healthy in `health()` (today checks `loaded==true`, remotes always `false`).
- `hybrid_weights` accepts both `{kw, vw}` tuple and `[keyword: x, vector: y]` list.
- `model_status` dims become observed-last-seen, `:unknown` before first embed.

Slice 2 — namespaced index with inferred active dim (B+A):
- One `vec_nodes_<dim>` table per observed dim, `CREATE IF NOT EXISTS` lazily on first vector.
- Per-request derived routing: `dim = byte_size(blob)/4`; no cached active-dim pointer.
- Query dim != table dim returns `{:error, :dim_mismatch}`; never compare across dims.
- Switch backfills only URIs missing in the active table (diff `nodes` vs active vec table); old tables retained.
- Explicit `prune(dim)` operator action only; boot never wipes; prune refuses the active dim.
- `index_coverage` reports `{active_dim, vectors, documents, needs_backfill}`; guard absurd dims and cap distinct dims.

Non-goals: keyword FTS5/BM25 rewrite, reranking, new managed providers, split embed/summarize providers.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `vector-search`: dim-namespaced index routing, `dim_mismatch` contract, `hybrid_weights` list+tuple compat, per-dim coverage/backfill reporting.
- `inference-providers`: remote request shape (`model` field, batched embeds), remote health semantics, observed dims, explicit prune.

## Impact

- Code: `adapters/inference/ollama.ex`, `adapters/inference/openai_compatible.ex`, `application/status.ex`, `application/search.ex`, `store/sqlite.ex`, `adapters/sqlite.ex`, `store/nodes.ex`.
- APIs: `search/2` gains `:dim_mismatch` error case on vector/hybrid legs; `hybrid_weights` accepts an additional shape; `health()` may flip degraded->ok for healthy remotes; new `prune` operator action.
- Data: additive `vec_nodes_<dim>` tables; existing `vec_nodes` (384) treated as `vec_nodes_384`; no automatic wipe.
- Verification caveat: sqlite-vec absent on this machine (`vec_available?` false); vector paths need a host with the extension or CI with it.
