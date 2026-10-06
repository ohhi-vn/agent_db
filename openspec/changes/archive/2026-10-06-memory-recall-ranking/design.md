# Design

## Context

See proposal.md Why. `recall` today (`application/memories.ex:106-127`, `store/memories.ex:116-142`): filter by exact-uri-or-descendant scope + status + optional `LIKE %term%` on value, `ORDER BY confidence DESC, uri, id`. Memories are ordinary nodes so they also get embedded (`memories.ex:83`), but recall never uses similarity. Filtered sets are small (dozens), so exhaustive re-rank is cheap.

## Goals / Non-Goals

**Goals:** paraphrase-robust recall without changing filtering semantics; deterministic blended order; graceful fallback without embeddings.
**Non-Goals:** FTS5/BM25, global index changes (see `fix-hosted-inference`), long-doc reranking, new providers.

## Decisions

1. Filter-then-rerank in `application/memories.ex`, not in SQL. Keep `Memories.list` as the authoritative filter (scope/type/active/term-substring as candidate gate); compute blend in the workflow over returned rows only. Rationale: no SQL/cosine in the hot filter, dim logic reused from search path, small-N exhaustive is trivial. Alternative (SQL JOIN to vec table) rejected: couples recall to vec availability and dim routing.
2. Blend `score = w_conf * norm(conf) + w_sim * sim + exact_boost` with defaults (e.g. 0.7/0.3 + small exact bonus), deterministic tiebreak by `(confidence DESC, uri, id)` preserving current order when sims tie/unavailable. Alternatives: RRF of two orderings (hides magnitude), pure-sim (loses provenance signal). Weights documented constants, not per-query options in v1.
3. Semantic input: embed the recall `term` once via `Runtime.inference().embed/1`; cosine against candidate values' embeddings fetched from the active vec table (reuse dim-safe lookup). On `:model_loading`/`:dim_mismatch`/unavailable: fallback to confidence order + `needs_backfill: true` signal (payload TBD: log + status, not error).
4. Eval fixture first: ~20 memories across types/confidences + ~20 paraphrased queries with expected top-1/top-3; measure recall@k for confidence-only vs similarity-only vs blended. Fixture lives in test/support, runs without network via fake embedder with scripted vectors.

## Risks / Trade-offs

- [Short-value embeddings noisy] → Mitigation: confidence dominates by default weight; eval fixture proves blend beats either alone or weights change.
- [Depends on hosted embedding health] → Mitigation: fallback path is spec'd; works fully local.
- [Expected-rank in fixture is subjective] → Mitigation: keep fixture small, obvious paraphrases only; reviewers eyeball diffs.

## Migration Plan

Additive ordering change only when a term is supplied; term-less recall byte-identical. No schema change. Rollback: restore confidence-only ordering.

## Open Questions

None blocking. Deferrable: exact default weights pending fixture numbers; exact `needs_backfill` surfacing (recall envelope vs status-only).
