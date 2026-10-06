# Proposal

## Why

Memories today are write-once facts with a static confidence: nothing learns from use, anything (including an LLM loop) can store anything, conflicting beliefs at different URIs coexist silently, and old facts rank as highly as fresh ones. The store needs the cheapest foundations of a memory lifecycle — usage tracking, an opt-in candidate gate, read-only conflict surfacing, and decay-aware ranking — without breaking its core invariants.

## What Changes

Slice 1 — usage tracking (additive, no contract break):
- Record `importance` at write time alongside `confidence`.
- Track when a memory is surfaced (`last_surfaced_at`) so recency/frequency exist for later policies.
- Reads that surface memories gain writer traffic; the "recall never writes" property is explicitly retired for surfaced rows.

Slice 2 — opt-in candidate gate (default off, no break):
- `remember` accepts an opt-in candidate status; candidates are recorded but excluded from default recall until explicitly promoted.
- The gate is rule-based first (dedup + confidence threshold); a model-backed evaluator is explicitly out of scope and needs its own change.
- Rejected candidates are removed without a trace (keeping `forget`'s promise); the gate's decisions are observable via debug logging, not stored audit rows.

Slice 3 — read-only cross-URI conflict surfacing (no resolution):
- Detect candidate conflicts reusing already-stored embedding vectors (same-type, high-similarity pairs); never run new inference for detection.
- Surface through a dedicated read outside `recall` — recall's result shape never changes.
- Detection inherits the embedding-availability caveat: conflicts are sometimes invisible, and that limitation is documented, not hidden.

Slice 4 — decay as ranking penalty + promotion as suggestion:
- Decay lands inside the existing blend score as a recency/frequency penalty term, reusing the `blend_score` weights pattern; no new lifecycle state, no deletion.
- Promotion is detect-and-suggest (surface repetition patterns, caller records the merged memory); auto-merge is out of scope (it needs a model on the write path).

Non-goals: taxonomy migration (the five-type URI-derived taxonomy stays), model-backed evaluation or merging, new lifecycle states (archived/weak/important), cross-device or multi-owner scoping, graph retrieval.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `memory`: surfaced-tracking (`importance`, `last_surfaced_at`), opt-in candidate status with explicit promote, conflict-surfacing read, decay-aware ranking for term recall.

## Impact

- Code: `application/memories.ex` (remember/recall/conflict read), `store/memories.ex` + `store/sqlite.ex` (additive `memory_meta` columns), `adapters/sqlite.ex` + test fakes (recall filtering/ranking parity).
- APIs: `remember/3` gains opt-in options (default behavior unchanged); `recall/1` gains no new options in slice 1–2; one new read function for conflicts; term-recall ordering gains a decay term.
- Data: additive nullable columns on `memory_meta` via the existing `add_missing_columns` mechanism; no rewrites, old stores gain the shape on boot.
- Invariants preserved: recording still needs no model; default recall shape and ordering contract hold until slice 4's additive penalty; `forget` still removes everything at the URI.

## Open Questions

- Q1 (non-blocking): the exact access signal — exact-URI reads only, or all recall appearances? Recommendation: count exact reads plus recall appearances but name the column `last_surfaced_at` to admit the ambiguity. Steps 3–4 inherit this definition.
