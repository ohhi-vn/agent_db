# Tasks

## 1. Eval fixture (measure first)

- [x] 1.1 Add paraphrase fixture (~20 memories across types/confidences + ~20 reworded queries with expected top-1/top-3) under test/support and verify it runs with the fake embedder and reports recall@k for all three modes
- [x] 1.2 Record baseline recall@k for confidence-only vs similarity-only and verify blended has headroom (blended target beats both)

## 2. Blended recall

- [x] 2.1 Implement filter-then-rerank blend in `application/memories.ex` (confidence + cosine + exact boost, deterministic tiebreak) reusing the dim-safe embed path and verify paraphrase fixture top-1 improves over baseline
- [x] 2.2 Implement embedding-unavailable/dim-mismatch fallback to confidence order with backfill signal and verify recall succeeds with vec index unavailable
- [x] 2.3 Verify term-less recall order is byte-identical to today and active-only/type-scope/empty-on-no-match semantics unchanged

## 3. Verification

- [x] 3.1 Run `mix test test/agent_db/memory_test.exs` plus new blend tests and verify green
- [x] 3.2 Run `openspec validate memory-recall-ranking --strict` and verify zero errors
