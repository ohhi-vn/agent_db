# Design

## Context

See `proposal.md` Why. Current state (observed, not assumed): search core
already accepts string modes (`Application.Search.do_search/2`) and
`SearchController.describe/1` maps error tuples to tags, so the
README-documented 500 class may be partially fixed — first step is
reproduce-or-close. Hybrid legs already run as Tasks with 10s timeout and
classified errors; `ModelManager` is one GenServer (60s call timeout)
serializing all inference; the job queue is SQLite-backed with optimistic
locking. Bench baselines and method live in `bench/baseline.md`, which
refuses absolute CI assertions.

## Goals / Non-Goals

**Goals:**
- Transport errors become JSON-safe, with correct statuses, and code-bearing on
  all four surfaces, sharing one taxonomy.
- Hot paths improve only on repeatable measured deltas; inference stops
  serializing behind unchanged contracts.

**Non-Goals:**
- No facade signature or result-shape changes; no new transports, dependencies,
  migrations, or config keys.
- No absolute latency SLOs in CI; no ModelManager redesign that changes load,
  retry, or `:model_loading` semantics.

## Decisions

- **Reproduce-or-close before fixing:** drive each README known-issue case
  against a running daemon first. Alternative assumed re-fix rejected — code
  already shows string-mode support that postdates the README note.
- **One error-code taxonomy, owned by `Observability`:** transports map
  reasons through `classify_reason/1` instead of each controller inventing
  shapes. Alternative per-transport handlers rejected — that is how the
  divergence happened.
- **Bench-gated perf, relative deltas only:** each optimization must show a
  repeatable `bench/agent_db_bench.exs` delta vs checked-in baseline on the
  same host; otherwise it is dropped. Alternative absolute budgets rejected —
  project convention and hardware variance forbid them.
- **Concurrency behind the port, not around it:** `ModelManager` parallelism
  (e.g. separate embed/summarize lanes or a pool behind the GenServer API)
  keeps `embed/1`/`summarize/2` contracts, grace-period, and retry semantics.
  Alternative caller-side parallelism rejected — it would push load policy
  onto every caller including background workers.
- **Phase order: errors → hot paths → inference → queue:** error mapping is
  small, testable, and de-risks later load testing; inference last because it
  needs warmed-model measurements plus runtime safety review.

## Risks / Trade-offs

- [Risk] README known-issue already fixed → Mitigation: reproduce-or-close
  task first; close the doc note instead of shipping a no-op fix.
- [Risk] Bench noise mistaken for gain → Mitigation: same-host repeats,
  `time: 3, memory_time: 1`, memory-unchanged check; drop unproven changes.
- [Risk] ModelManager concurrency introduces load races → Mitigation: keep
  single-writer invariants for model state; full `mix test` plus warmed-model
  soak before accepting.
- [Risk] Stricter statuses break a client parsing old 500s → Mitigation:
  responses stay JSON with reason strings; codes are additive, statuses only
  move wrong→right (never the reverse).

## Migration Plan

No migration. Ship behind no flag; error shapes are additive (new `code`
field) and status corrections are bug fixes. Rollback is `git revert` per
phase. Update `bench/baseline.md` only with measured deltas; correct the
README Known-issues section as defects close.

## Open Questions

None — measurement hosts and repeat criteria are fixed by the bench method;
remaining unknowns (exact hotspots) are answered by profiling tasks, not by
further planning.
