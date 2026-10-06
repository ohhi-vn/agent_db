# Design

## Context

See proposal.md Why. Current state: one `vec_nodes float[384]` table (`store/sqlite.ex:373-379`), raw-blob `put_embedding_result` with no dim tag (`adapters/sqlite.ex:220-234`), `vec_distance_cosine` assuming matching dims (`adapters/sqlite.ex:301-307`), hardcoded dims in 4 places, `health()` requiring `loaded==true` (`application/status.ex:116-119`), tuple-only `hybrid_weights` (`application/search.ex:246`), OpenAI bodies without `model`, Ollama N+1 embeds. No reindex path; `ensure_schema` is additive/idempotent.

## Goals / Non-Goals

**Goals:**
- Hosted adapters correct and observable without changing call contracts.
- Dim-safe vector storage with no silent cross-dim comparison and no boot wipe.
- Switch-back cheap; backfill incremental; prune explicit.

**Non-Goals:**
- FTS5/BM25 keyword rewrite, reranking, new providers, per-role embed/summarize split, vector compaction/optimization passes.

## Decisions

1. Per-request derived dim (`byte_size(blob)/4`) over cached pointer or config-pinned dims.
   Rationale: no stale-pointer class, custom providers need zero config, always truthful. Alternatives: cached ETS pointer (stale risk, multi-node questions), config dims (drift when hosted model changes). Cost accepted: DDL partly on write path via `CREATE IF NOT EXISTS`, one int div + exists check per op.
2. Namespaced tables `vec_nodes_<dim>` (B+A) over single-table drop+recreate.
   Rationale: typo/misconfig creates an empty table instead of deleting good vectors; switch-back instant when coverage full. Alternative pure-B (drop+recreate) rejected: destructive on env typo. Table proliferation bounded by guard (refuse 0/>8192, cap distinct dims, log).
3. Backfill = diff `nodes` (kind doc) vs active vec table, enqueue `:embed` only for missing URIs through existing durable `job_queue` + `Embedding` worker. No new queue; reuses retry/defer semantics. Thin-search window remains but only for new dim.
4. `dim_mismatch` as classified error on vector/hybrid legs, never misrank. Hybrid keeps both-legs-required semantics; mismatch surfaces like other leg failures.
5. `hybrid_weights` compat shim accepting tuple and keyword list, normalized once in `search.ex` before `fuse/3`.
6. Health: `embedding_ready?` checks `state==:ready` (or equivalent) instead of `loaded==true`; `model_status.dim` = last observed or `:unknown`. Display literals remain but are never routing truth.
7. OpenAI `model` from config/env (new `openai_embed_model`/`openai_llm_model` keys with env fallback, defaulting to current `"openai-compatible"` literal for compat); Ollama batch with per-text fallback on server 400.

## Risks / Trade-offs

- [sqlite-vec absent here] → Mitigation: mark vector tasks env-gated; verify DDL/routing on host with extension or CI with it; keep `vec_available?` guards on every new vec statement.
- [Backfill hammers hosted endpoint: N jobs, 10s timeouts, 429s] → Mitigation: reuse `inference_concurrency`, existing fail/defer; document rate-limit tuning; batch Ollama to cut calls.
- [First-write DDL race] → Mitigation: `CREATE VIRTUAL TABLE IF NOT EXISTS`; concurrent creators converge.
- [Absurd/proliferating dims from bad provider] → Mitigation: validate dim range, cap distinct tables, error + log, never auto-create beyond cap.
- [Ollama batch shape varies by server] → Mitigation: try batch, fall back to per-text on rejection; covered by test with fakes.
- [Hybrid still vector-weak mid-backfill] → Accepted; keyword leg unaffected; coverage endpoint shows progress.

## Migration Plan

- Deploy: additive tables only. Existing `vec_nodes` (384) treated as `vec_nodes_384` (alias or rename-once behind `vec_available?`; prefer alias view/shim to avoid rewrite). No wipe on boot. Rollback: flip provider back; old tables intact. Prune only via explicit action.
- `ensure_schema`: adds `IF NOT EXISTS` creation for observed-dim tables + guarded prune helper; no framework change.

## Open Questions

None blocking specs/approach/tasks. Deferrable: exact `prune` surface (public `AgentDb` fn vs mix task vs both) — default to public fn + console hook; exact coverage payload keys — default `{active_dim, vectors, documents, needs_backfill}`.
