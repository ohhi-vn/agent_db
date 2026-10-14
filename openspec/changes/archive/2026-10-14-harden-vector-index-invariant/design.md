# Design

## Context

See `proposal.md` for motivation. What matters for the approach:

- `AgentDb.Core.Storage` is a port implemented by one adapter,
  `AgentDb.Adapters.SQLite`. Its moduledoc states that a storage adapter owns
  every record keyed by URI "because those records have to agree with each
  other," and that `remove_subtree/1` removes from every one of those stores
  "in one atomic step."
- The read-side join already exists and already does the work: `run_vector_search/5`
  emits `FROM vec_nodes_<dim> v JOIN nodes n ON n.uri = v.uri`. A vector row
  naming a removed URI produces no rows. The archived `harden-node-removal`
  proposal states this explicitly — it is what made the orphan leak silent.
- `AgentDb.Store.Nodes.delete_vec_nodes/2` already iterates `list_vec_dims/1`
  and deletes per-dimension rows for a subtree. The per-URI version of that
  operation does not exist; every `DELETE FROM vec_*` is either subtree removal
  or boot-time reconciliation.
- `reconcile_orphan_embeddings/1` runs once inside `ensure_schema/1` — at boot
  only. Nothing reclaims drift while the application runs.
- The vector leg already over-fetches: `fetch_limit = min(limit * 3, 200)` in
  `AgentDb.Application.Search`, for the disabled-interleave reason.
- `job_queue.kind` is `TEXT NOT NULL` with no CHECK constraint, so adding a job
  kind needs no schema migration. `defer_job/2` exists for work that is merely
  waiting and must not spend an attempt.
- `AgentDb.Runtime` resolves providers (`Runtime.storage/0`,
  `Runtime.inference/0`); `AgentDb.Cache` is disposable ETS, and
  `data-portability` already re-enqueues embedding on import rather than
  exporting it. Derived-vs-authoritative classification already has precedent.

## Goals / Non-Goals

**Goals:**
- The vector index becomes a derived engine behind an explicit port, so its
  behaviour is testable without an engine and a second engine can be added
  without touching read paths.
- The safety guarantee is relocated to the read path, where it already holds,
  and made *observable* so drift cannot become silent again.
- A document is never ranked by content it no longer has, whether the new
  content arrived by re-write or by re-creation.

**Non-Goals:**
- Adopting `lancedb_ex` or any second engine. That is a separate change this
  one makes safe.
- Any public API change. `search/2`, `write/3`, and `rm/1` keep their signatures
  and their `{:ok, _}` / `{:error, _}` contracts.
- Making the index durable-accurate. The point is that it no longer has to be.

## Decisions

### 1. Classify the vector index as derived, in the port's own words

`Core.Storage`'s invariants are rewritten to name which stores are
authoritative (nodes, memories, commit bookkeeping, job queue) and which are
derived (the vector index, and the ETS cache, which already is).

```
   BEFORE                                    AFTER
   -----                                     -----
   "a storage adapter owns every           "the relational record is
    record keyed by URI, because            authoritative; the vector
    those records have to agree             index is derived and may lag"
              |
       one engine, one transaction  -->  read path joins back
                                          to the authoritative record;
                                          drift is bounded and reclaimed
```

**Alternative considered:** keep the invariant and forbid a second engine.
Rejected: it protects nothing the read path does not already protect, and it
is the reason the index cannot be tested in isolation.

### 2. Enforce the guarantees where every provider already agrees

`AgentDb.Core.Storage` is the contract, `AgentDb.StorageContract` is the suite
that measures every provider against it, and `AgentDb.Test.Fakes.Storage` is a
programmable in-memory provider behind the same seam. The read-path join,
retire-on-write, the result bound and index containment are therefore stated as
contract requirements and implemented in each provider, rather than as an
orchestration layer above one.

A second port was considered and rejected. `Runtime.validate!/0` requires every
entry in `@ports` to be fully implemented by the configured adapter, so a
separate vector port would force a second adapter key through every test that
swaps `:storage_adapter`; the shared suite would fork; and `backfill_vector_index/0`,
`prune_vector_index/1` and the dim-routing refusal all need the node/index join
that belongs to the provider. The existing seam already delivers the separability
the port was meant to buy.

**The test double was not faithful, and fixing it is part of this change.**
`Fakes.Storage.search_vector/3` builds a hit for any URI in the embeddings map,
hydrating with `content_at/1`, which yields `nil` for a URI the document map no
longer holds. A removed URI whose vector row survives is therefore *returned* by
the fake, while the SQLite provider hides it behind `JOIN nodes`. The contract
suite never exercised a surviving row for a removed URI, so the divergence was
invisible. The new scenarios are added to the shared suite so both providers are
measured, and the fake is brought into agreement.

### 3. Retire a URI's vector on write, in the same writer transaction

`put_document/3` deletes the vector rows for the URI it writes, from every
dimension, in the same writer transaction that persists the document. It is the
per-URI twin of `delete_vec_nodes/2`, using the same `list_vec_dims/1` walk.

Deleting derived data that will be regenerated can only make vector search
return less, never return something the store cannot hold — so the failure mode
is a *miss*, not a *false positive*, which is the safe direction for a search
index. The cost is a few DELETEs per write, measured by the existing write
scenario.

**Alternative considered:** leave re-write alone and rely on
`ON CONFLICT(uri) DO UPDATE` to replace the row when the new embedding lands.
Rejected: that leaves the window the `harden-node-removal` proposal named and
never closed — a live document ranked by its previous content, from the moment
the write is acknowledged.

### 4. Reclamation as a self-rescheduling durable job

A new job kind, `:reclaim_vector_index`, claimed by a worker that claims only
that kind — required because `dequeue_job/1` is filtered by kind precisely so "a
worker never claims work it cannot run."

```
boot --> enqueue(reclaim_vector_index, payload: %{})
          |
          v
      claim --> count reclaimable rows
                 |
        +--------+--------+
        |                   |
     rows to delete      nothing to do
        |                   |
     delete, count     defer_job(0 attempts spent,
     reclaimed,          reschedule in cadence)
     re-enqueue
          |
          v
      cadence elapses --> repeat
```

`defer_job/2` is the right call for the "nothing to do" path: the job keeps its
attempt budget and simply comes back later, which is what makes an idle store's
reclamation cost one cheap count per cadence rather than a full scan. Failure
modes never exhaust the budget — an index that cannot be reached is deferred,
not failed, so reclamation never becomes poison.

Boot-time `reconcile_orphan_embeddings/1` is retained. It is idempotent and
covers a store that is opened by a tool that never starts the application (the
import path).

**Alternative considered:** a timer inside a GenServer. Rejected: it is not
observable through `queue_stats/0`/`queue_detail/1`, does not survive restart as
scheduled work, and gives an operator no way to see that reclamation is
stalled — which is the failure that caused the original silent leak.

### 5. Drift becomes observable

`AgentDb.index_coverage/0` gains a `reclaimable` count: index rows whose URI
the authoritative record no longer holds, reported without scanning content.
The number is the health signal. A store where reclamation is broken reads as
a growing `reclaimable`; today it reads as nothing at all.

This is the direct lesson of `harden-node-removal`: *"the JOIN nodes ... hides
orphans from results, so the leak is silent."* The fix for silence is a number.

### 6. The over-fetch margin stays; its adequacy is now derived, not assumed

`min(limit * 3, 200)` stays. Its correctness for orphans is a consequence of
the other two mechanisms rather than luck: retire-on-write removes the rows a
re-write would orphan *before* they are orphaned, and reclamation bounds what
races leave behind to in-flight jobs. A `3x` margin covers a population that
can only grow as fast as concurrent embedding jobs race removals.

**Alternative considered:** hydrate-and-fill with a bounded round of paged
requests until `top_k` survivors are collected. Rejected: it needs an offset in
the index callback signature, and it converts a bounded, cheap guarantee into an
unbounded read that a pathological index can turn into a loop. If drift ever
proves larger than the margin, the right response is to look at `reclaimable`,
not to widen the fetch.

### 7. Containment boundary and a retryable overload class

The provider normalises what reaches the caller:

```
   provider raises              -> {:error, :vector_index_unavailable}
   provider returns {:error, _} -> classified as-is
   Kind: == :busy               -> {:error, :vector_index_unavailable}  (retryable)
   anything else                -> passed through to the existing taxonomy
```

`:busy` maps to *unavailable, retry*, never to a new failure class and never to
a permanent one. A worker that sees it defers rather than fails. The boundary is
tested by scripting the fake storage provider to raise and to saturate: the
assertions are that the caller receives an error tuple and that no process dies.
No engine in this change emits `:busy`; the boundary is what a future engine
will need, and the fake is how it is verified before one exists.

The reason for the emphasis: `erl_crash.dump` from 2026-10-13 shows an
`ArgumentError` raised inside a `GenServer.call` whose *error printer* then
died on a closed `standard_error`, killing the runtime during boot. The
diagnostic for the original error died with it. An index that is allowed to
raise into a caller reintroduces exactly that shape.

## Risks / Trade-offs

**[Residual drift reduces result counts]** → retire-on-write removes the common
cause before it becomes drift; reclamation bounds the rest; `3x` over-fetch
covers the bound; `reclaimable` makes it visible instead of silent. A count
lower than `top_k` is still a *correct* result, just a thin one.

**[Reclamation adds write-path work]** → one DELETE per dimension per write on
a `@max_vec_tables` of 16, inside a transaction that already does several. The
write benchmark scenario is the check; a regression is the trigger to batch the
per-dimension deletes into one statement list.

**[Reclamation competes with live work]** → it is a durable job on the same
queue, so it is rate-limited by the queue, observable through `queue_detail/1`,
and never claims work another kind owns.

**[The weakened invariant is used to justify worse behaviour later]** → the
requirement text is explicit that removal *shall* make a URI unsearchable and
*shall* reclaim its rows; only the "in the same step" claim is dropped. The
remaining claim is enforced by a shared contract scenario that gives the fake
provider a vector row for a URI it does not hold.

**[The read-path join becomes load-bearing rather than incidental]** → it moves
from an implementation detail to a stated requirement with its own scenario and
its own test. That is the intent, not a side effect.

## Migration Plan

No data migration. Existing `vec_nodes_<dim>` tables are unchanged in shape and
content; a store written by the previous version is served correctly by the new
one.

**[The read-path join becomes load-bearing rather than incidental]** → it moves
from an implementation detail to a stated requirement with its own scenario and
its own test in the shared contract suite. That is the intent, not a side effect.

## Migration Plan

No data migration. Existing `vec_nodes_<dim>` tables are unchanged in shape and
content; a store written by the previous version is served correctly by the new
one.

1. Land the invariant rewrite, the faithful fake, and the shared contract
   scenarios covering the read path and the result bound.
2. Enable retire-on-write and the reclamation job.
3. Surface `reclaimable` through `index_coverage/0`.

Rollback is a code revert: the vector tables remain valid under the old code,
because the new code never changes what is stored — only what it deletes.

Ordering matters for one reason only: steps 1 and 2 must land together, because
retire-on-write without the read-path join stated would make the write path
delete data on the strength of a guarantee nothing yet enforces.

## Open Questions

- **Reclamation cadence default.** A new config key with a default measured
  against how fast drift accumulates in practice. No requirement depends on the
  value, and no task needs it to be right to be written.
- **Console surfacing of `reclaimable`.** Putting the number on the Storage page
  of `/admin` would add a requirement to `admin-dashboard`, so it is left out of
  this change's scope. The number exists in the API; a follow-up can surface it.
- **Margin constant.** `3x / 200` is inherited from the keyword leg. If drift
  ever exceeds it, the response is a cadence change, not a margin change — see
  decision 6.
