# Proposal

## Why

`AgentDb.Core.Storage` states that a storage adapter owns every record keyed by
URI — documents, **the vector index**, the job queue, and memory assertions —
"because those records have to agree with each other," and that
`remove_subtree/1` removes a URI from every one of those stores "in one atomic
step." That invariant was written by `harden-node-removal` (2026-09-26) in
response to a real resurrection bug. But reading that change's own proposal
against the code that resulted shows the invariant is aimed at the wrong lever:
it states that *"the JOIN nodes in vector_search_impl **hides orphans from
results**, so the leak is silent"* — the read-side join, not the atomic write,
is what keeps a removed URI out of vector results.

The invariant therefore buys little and costs a design limitation: it welds the
vector index into the authoritative transaction, which makes the index
inseparable and untestable in isolation, and it leaves the one hazard that
actually bites entirely unaddressed. `put_document/3` never clears the vector
row for the URI it writes. Every `DELETE FROM vec_*` in the codebase is either
subtree removal (`lib/agent_db/store/nodes.ex:170`) or boot-time orphan
reconciliation (`lib/agent_db/store/sqlite.ex:666`). A document re-written at a
URI that already holds an embedding is therefore ranked by content it no longer
has, from the moment the write is acknowledged until its own re-embed lands —
`context-store`'s "recreated URI" scenario covers this only after a removal, not
after an ordinary re-write.

## What Changes

- **Rewrite the storage invariants** in `Core.Storage` to classify the vector
  index as *derived* rather than authoritative, alongside the ETS cache. The
  relational record (nodes, memories, sessions, commit bookkeeping, job queue)
  stays authoritative and atomic; the index may lag, and the guarantee moves to
  where it already holds.
- **Relocate the guarantee to the read path.** Every vector hit is joined back
  against the authoritative node record, so a removed URI cannot be returned
  while a row naming it survives. This is already the implementation
  (`JOIN nodes n ON n.uri = v.uri` in `run_vector_search/5`); it becomes
  *stated* rather than incidental.
- **Bound and reclaim drift instead of forbidding it.** Removal guarantees the
  URI becomes unsearchable, not that a row is gone. Orphans become an
  operational cost with a reclamation path — the reconciliation that already
  runs at boot becomes a durable background job.
- **Close the live-document staleness window.** A write at a URI that holds a
  vector clears that vector in the same step. Deleting derived data that is
  about to be regenerated can only make vector search return less, never wrong.
- **Introduce a `Core.VectorIndex` port** with the existing sqlite-vec
  implementation behind it, so the index is adversarially testable without an
  engine and a second engine can be added later without touching read paths.
- **Over-fetch on the vector leg.** `LIMIT top_k` inside a nearest-neighbour
  query consumes orphan candidates, so a scope holding drift can return fewer
  results than `top_k`. The keyword, `grep`, and `find` legs already over-fetch
  for the disabled-interleave reason; the vector leg needs the same margin.
- **Classify index overload as retryable.** Backpressure from the index must
  land in the existing error taxonomy as a retryable unavailability, never as a
  new failure class, and must never escape as an exception into a `GenServer.call`
  — the shape that destroyed the runtime in today's `erl_crash.dump`.

No new dependencies. No public API change: `AgentDb.search/2`,
`AgentDb.write/3`, and `AgentDb.rm/1` keep their signatures and their
`{:ok, _}` / `{:error, _}` contracts.

## Capabilities

### New Capabilities

None. The behaviour being specified already belongs to existing capabilities;
a new one would be a near-duplicate.

### Modified Capabilities

- `vector-search`: The index-persistence requirement is rewritten from
  atomic-agreement ("no entry for a removed URI") to derived-index semantics
  (searchability plus reclamation), the read-side join becomes an explicit
  requirement, over-fetch is required, and backpressure becomes a retryable
  unavailability rather than a new failure class.
- `context-store`: The "Subtree removal is complete and durable" requirement is
  narrowed to authoritative stores, with the derived index guaranteed
  unsearchable and reclaimed rather than instantly gone; a new scenario covers
  an ordinary re-write at a URI holding an embedding.

## Impact

- **Specs:** `openspec/specs/vector-search/spec.md`,
  `openspec/specs/context-store/spec.md` (via delta specs in this change).
- **Code:** `lib/agent_db/core/storage.ex` (invariants and callback set),
  `lib/agent_db/adapters/sqlite.ex` (`search_vector/3`, `put_embedding_result/3`,
  `vector_index_stats/0`), `lib/agent_db/store/sqlite.ex`
  (`reconcile_orphan_embeddings/1` moves from boot-only to a durable job),
  `lib/agent_db/store/nodes.ex` (re-write clears the URI's own vector rows),
  `lib/agent_db/application/search.ex` (over-fetch margin and hydration),
  `lib/agent_db/application.ex` (job registration for reclamation).
- **Module documentation:** `lib/agent_db/core/storage.ex`'s invariant list, and
  `guides/ARCHITECTURE.md`, which describes the context-store component
  boundary and the vector index in terms that must be restated as derived
  rather than authoritative.
- **Tests:** a test-only hostile vector index adapter asserting the read-path
  invariant, plus scenarios for re-write staleness and short-result counts.
- **Dependencies:** none added.
- **Explicitly out of scope:** adopting `lancedb_ex`. A second engine is a
  separate change that this one makes safe, and doing both at once would put a
  rewritten safety invariant and a brand-new Rust NIF in one unreviewable diff
  on a platform where neither can run.
