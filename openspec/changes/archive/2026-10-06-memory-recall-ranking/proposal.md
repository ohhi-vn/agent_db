# Proposal

## Why

Agent `recall` matches terms by substring and orders by confidence, while scoped `search` orders by similarity — paraphrased memories ("likes Elixir" vs "prefers Elixir over Go") fall through both. Blend the two within the filtered set so firmly-held relevant facts outrank weakly-held phrasing matches.

## What Changes

- `recall` with a term/query blends confidence + semantic similarity over the already-filtered active set (type/uri scope), instead of confidence-only.
- Exact-substring matches get a small boost; active-only, type-scope, and empty-on-no-match semantics unchanged.
- When embeddings are unavailable or dim-mismatched, recall falls back to confidence-only and reports backfill needed rather than failing.
- New paraphrase eval fixture (~20 memories x reworded queries) measuring recall@k for structured-only vs semantic-only vs blended.

Non-goals: FTS5/BM25 keyword rewrite, global vector index changes (owned by `fix-hosted-inference`), per-role providers, reranking long documents.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `memory`: recall ranking blends confidence with semantic similarity; fallback and eval behavior.

## Impact

- Code: `application/memories.ex` (blend + fallback), reuse of `Runtime.inference().embed/1`, possibly `store/memories.ex` for value+embedding join; eval fixture + tests.
- APIs: `recall/1` result order may change when a term is given; no signature change; no new required config.
- Depends on `fix-hosted-inference` slices 1-2 for healthy hosted embeddings and dim-safe tables, but degrades gracefully without them.
