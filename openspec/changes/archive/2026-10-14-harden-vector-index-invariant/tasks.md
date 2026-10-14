# Tasks

## 1. State the invariants

- [x] 1.1 Rewrite `Core.Storage`'s moduledoc invariant list to name authoritative
  stores (nodes, memories, commit bookkeeping, job queue) versus derived ones
  (vector index, ETS cache), and to state the read-path-join, bounded-and-reclaimed
  and never-ranked-on-stale-content guarantees in place of one-atomic-step. Verify
  with `mix format --check-formatted` and `mix credo --strict` both clean.
- [x] 1.2 Record the derived-index contract on the vector-index callbacks
  themselves — that a hit is only returned for a URI the node store can hold, that
  the result bound is honoured, and that a raise never escapes. Verify with
  `mix compile --warnings-as-errors`.

## 2. Make the test double faithful

- [x] 2.1 Change `AgentDb.Test.Fakes.Storage.search_vector/3` so a hit is only
  built for a URI the fake's document map actually holds, dropping candidates
  whose document was removed while their vector row survives. Verify with
  `mix test test/agent_db/vector_index_safety_test.exs`.
- [x] 2.2 Add fake-only helpers that plant a vector row for a URI with no
  document, and one that stations a vector for a live URI whose content it no
  longer matches, so the contract suite can express drift directly. Verify both
  by asserting the planted row is invisible to `search_vector/3`.

## 3. Retire a URI's vector on write

- [x] 3.1 Add the per-URI vector twin of `Nodes.delete_vec_nodes/2` and call it
  from `put_document/3` inside the same writer transaction that persists the
  document, and from the fake's `record/3` so both providers honour the same
  contract. Verify the write path tests pass.
- [x] 3.2 Assert the re-write scenarios against the real provider, and confirm
  the `context-store` recreated-URI scenario still holds. Verify
  `mix test test/agent_db/store` passes.
- [x] 3.3 Measure the added write-path cost with the `write` benchmark scenario
  and record the delta against `bench/baseline.md`. Verify the regression is
  within run-to-run noise or is reported.

## 4. Enforce the guarantees in the shared contract suite

- [x] 4.1 Add a scenario to `StorageContract` giving a provider a surviving vector
  row for a removed URI and asserting no search returns it. Verify it fails
  against the pre-fix fake and passes after task 2.1.
- [x] 4.2 Add a scenario asserting a re-written document is not ranked on its
  previous content, and one asserting a URI with no prior vector behaves as a
  fresh write. Verify both pass under the real provider too.
- [x] 4.3 Add a scenario asserting the result bound holds when candidates cannot
  be hydrated, and one asserting a scripted raise or saturation returns
  `{:error, :vector_index_unavailable}` without terminating the caller. Verify
  `mix test` passes with the fake scripted to raise.
- [x] 4.4 Add fake-only tests for planted drift and a planted stale vector on a
  live URI, where the contract suite cannot reach because only the fake can
  create either state. Verify `mix test test/agent_db/vector_index_safety_test.exs`
  passes.

## 5. Reclaim drift while the application runs

- [x] 5.1 Add the `:reclaim_vector_index` job kind and its worker, claiming only
  that kind, and the boot-time enqueue. Verify a fresh store reports the job
  through `AgentDb.queue_stats/0` and `queue_detail/1`. No migration is needed:
  `job_queue.kind` has no CHECK constraint.
- [x] 5.2 Make the job self-rescheduling through `defer_job/2` when idle, and
  never exhausting its attempt budget when the index is unreachable. Verify an
  idle store's reclamation costs one count per cadence and a stalled index shows
  as deferred rather than failed in `queue_detail/1`.
- [x] 5.3 Cover the reclamation scenarios: rows naming absent URIs are deleted,
  rows naming live URIs are untouched, and no restart is required. Verify
  `mix test` passes and boot-time `reconcile_orphan_embeddings/1` still runs
  unchanged for stores opened through the import path.
- [x] 5.4 Add the cadence config key with its default and document it in
  `guides/SETUP.md` alongside the other configuration keys. Verify the
  documented default matches the code and the key is readable through
  `AgentDb.Config`.

## 6. Make drift visible
- [x] 6.1 Add a `reclaimable` count to the vector-index coverage reported by
  `AgentDb.index_coverage/0`, computed without walking content. Verify the
  number is non-zero exactly when an index holds rows for absent URIs and zero
  on a clean store.
- [x] 6.2 Assert the observability contract in a test: drift introduced through
  the fake shows up in the count, and reclamation returns it to zero. Verify
  `mix test` passes.

## 7. Integration

- [x] 7.1 Restate the vector index and the context-store component boundary in
  `guides/ARCHITECTURE.md` as derived-with-a-read-path-join rather than
  transactional, and verify the guide's claims match the code by following each
  one against `lib/`.
- [x] 7.2 Add a vector and hybrid-leg scenario to `bench/agent_db_bench.exs`
  (gated on the embedding model being loadable, following the existing error
  path) and run the harness on a host with cached weights. Verify the new
  numbers are recorded in `bench/baseline.md` with their inputs.
- [x] 7.3 Run the full local gates — `mix format --check-formatted`,
  `mix credo --strict`, `mix dialyzer`, `mix test` — and confirm each reports
  separately. Verify `mix lint` passes with no new entry in
  `.dialyzer_ignore.exs`.
- [x] 7.4 Re-read every delta-spec requirement against the implementation and
  confirm each scenario is exercised by a test. Verify `openspec validate
  --changes` passes and no requirement is left without a scenario.

## Workflow follow-up

- Archive the change once the project's review requirements are satisfied.
- Confirm the archived specs land under `openspec/specs/vector-search/spec.md`
  and `openspec/specs/context-store/spec.md` with both capability scenarios intact.
- Decide whether `reclaimable` should also reach the `/admin` Storage page; that
  would add a requirement to `admin-dashboard` and is deliberately left out here.
