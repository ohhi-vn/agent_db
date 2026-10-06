# Design

## Context

See proposal.md Why. Current state: `memory_meta(id, uri, value, confidence, source, status, supersedes, created_at, updated_at)` with `add_missing_columns` migration support (`store/sqlite.ex`); `Application.Memories` owns remember/recall/forget with confidence-ordered recall plus a term blend (`blend_score` with confidence/similarity/exact-boost weights); recall is read-only through `Reader`; every memory enqueues one `:embed` job, so vectors for all values already exist.

## Goals / Non-Goals

**Goals:**
- Usage signal and importance stored additively, feeding rank without new states.
- Candidate gate that preserves "no model required to record".
- Conflict visibility with zero resolution semantics.
- Decay expressed as a ranking term, promotion as caller-performed recording.

**Non-Goals:**
- Taxonomy changes, new lifecycle states, auto-merge, model-backed judging, owner scoping, graph retrieval.

## Decisions

1. Tracking columns on `memory_meta` (`importance REAL`, `last_surfaced_at INTEGER NULL`) via `@added_columns`, not a new table.
   Rationale: one row per assertion already exists; a side table would need a join on every recall for no benefit. Alternatives: ETS/event log (loses durability, duplicates queue history). NULL means "never surfaced", which the decay term treats as maximally stale — honest, since it is.
2. Surfacing counted on exact-URI reads plus recall appearances, column named `last_surfaced_at`.
   Rationale: exact reads are the clean signal; recall appearances are the available one. The name admits the ambiguity so the decay policy never claims more than "surfaced". Alternative `last_accessed_at` rejected: implies deliberate access the store cannot observe.
3. Recall performs its own surfacing writes on the writer connection after reading.
   Rationale: keeps read-then-touch atomic per row set; reuses the existing Writer serialization. Accepted cost: recall is no longer read-only, and high-traffic recall adds write load. Alternative fire-and-forget async touch rejected: loses durability ordering and complicates tests.
4. Candidate as a stored status excluded from default recall, promoted by explicit call; gate rule-based (dedupe + confidence threshold).
   Rationale: preserves every shipped contract by default-off; rule-based judging needs no model and matches the existing validation style (`invalid_memory_type`, `invalid_confidence`). Alternative model-backed evaluator rejected for this change: it needs fallback semantics of its own and deserves a separate proposal.
5. Conflict detection over stored vectors with cosine threshold within same type; surfaced via a dedicated read, never inside `recall`.
   Rationale: vectors already exist per value, so detection costs queries, not inference; keeping it out of recall freezes recall's shape. Same-type scoping bounds pair comparisons and matches the taxonomy's filing semantics.
6. Decay as an additive penalty term in `blend_score` (recency/frequency of `last_surfaced_at`), following the existing weights-plus-fixture pattern (`blend_weights/0`, `memory_ranking_fixture.ex`).
   Rationale: no new states, no deletion semantics to argue about, evaluable against the fixture like the current weights. Promotion stays caller-side: surface repetition patterns in the conflict-style read; the merged memory is an ordinary `remember`.

## Risks / Trade-offs

- [Write amplification on recall] → Mitigation: single batched touch per recall on the serialized writer; document the retired "recall never writes" property.
- [Surfaced-signal noise] → Mitigation: honest column naming; decay weight kept small relative to confidence/similarity in the fixture evaluation.
- [Detector false positives] → Mitigation: read-only surfacing means a wrong pair costs attention, not data; threshold tuned against the fixture, documented as heuristic.
- [Thresholds without production data] → Mitigation: fixture-driven numbers first, all weights in one place (`blend_weights/0` extended), tunable without migration.
- [Candidate rejection audit gap] → Accepted; debug logging only, per proposal. Revisit if operators ask what the gate drops.

## Migration Plan

- Deploy: additive nullable columns; old databases gain them on boot via `add_missing_columns`; NULL importance reads as the documented default, NULL `last_surfaced_at` as never-surfaced. Rollback: new columns ignored by old code; no data rewritten. No backfill of surfacing history (nothing to backfill from).

## Open Questions

- Q1 from proposal (access-signal exact definition) is decided here as Decision 2; the remaining tunable is the decay half-life weight, to be set against the fixture during implementation.
