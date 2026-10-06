# Tasks

## 1. Slice 1 — Surfaced tracking + importance

- [x] 1.1 Add nullable `importance` and `last_surfaced_at` columns to `memory_meta` via `@added_columns` and verify a legacy database gains both on `ensure_schema` without rewriting rows
- [x] 1.2 Accept `:importance` in `remember/3` (validated 0.0..1.0, documented default when omitted) and expose `importance` plus `last_surfaced_at` on recall entries, with fakes kept in parity
- [x] 1.3 Touch surfaced rows on recall (exact-URI reads plus recall appearances) on the writer connection and verify a recalled memory reports a surfaced time while an unrecalled one stays NULL
- [x] 1.4 Run `mix test test/agent_db/memory_test.exs test/agent_db/memory_recall_ranking_test.exs` and verify green

## 2. Slice 2 — Opt-in candidate gate

- [x] 2.1 Record opt-in candidates excluded from default recall, with explicit promote making the candidate active and reject removing it without a trace, and verify each transition
- [x] 2.2 Apply the rule-based gate (dedupe + confidence threshold, no model) and verify a duplicate or below-threshold record stays a candidate while a clean record is unaffected by default
- [x] 2.3 Run the memory contract tests against both SQLite and fakes and verify candidate rows never leak into default recall on either provider

## 3. Slice 3 — Read-only conflict surfacing

- [x] 3.1 Detect same-type high-similarity pairs over stored vectors without new inference and verify a paraphrased near-duplicate at two URIs is reported while distinct memories are not
- [x] 3.2 Expose detection through a dedicated read outside `recall`, verify recall shapes are byte-identical with the feature on, and verify unavailable embeddings report unevaluable rather than empty
- [x] 3.3 Run `mix test test/agent_db/memory_recall_ranking_test.exs` and verify the blend fallback contract still holds (recall never fails for want of an embedding)

## 4. Slice 4 — Decay penalty + promotion-as-suggest

- [x] 4.1 Add a recency/frequency penalty term to `blend_score` reusing the weights-plus-fixture pattern and verify a stale memory ranks below an otherwise equal fresh one in the eval fixture
- [x] 4.2 Surface repetition patterns suggesting promotion candidates without auto-merging and verify suggested merges are ordinary caller-recorded memories
- [x] 4.3 Run the full memory-related suites plus `mix test test/agent_db/adapters/sqlite_contract_test.exs` and verify green

## 5. Verification

- [x] 5.1 Run `openspec validate --change memory-lifecycle-foundations --strict` and verify zero errors
