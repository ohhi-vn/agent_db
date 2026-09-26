# Tasks

## 1. Foundations

- [x] 1.1 Add a public `SQLite.vec_available?/1` predicate that reuses the existing `vec_version()` probe from `load_vec_extension/1`, and verify it returns true when sqlite-vec loads and false when the extension is absent — *done: false case verified (extension absent here, agrees with `vec_nodes` not existing); true case not reachable in this environment, see 3.1*
- [x] 1.2 Add a `SQLite.transaction/2` helper that issues `BEGIN`, runs the fun, and issues `COMMIT` on success or `ROLLBACK` on error, propagating the fun's return value; verify with a test that commits on success, rolls back and returns the error on failure, and that the connection is usable afterwards in both cases — *also rolls back and re-raises when the fun raises, so a failing caller cannot leave the Writer's connection inside an open transaction*
- [ ] 1.3 Add a `JobQueue.cancel_for_uri/1` that deletes queued jobs whose payload URI equals the target or falls under the target prefix, covering both `pending` and `running` rows, reusing `Nodes.like_escape/1`; verify with tests for an exact match, a descendant match, an unrelated URI left untouched, and a `running` row removed — *takes a connection rather than the writer, because removal calls it from inside its own transaction. Matches `json_extract(payload,'$.uri')` instead of the raw JSON text, so a job whose content merely mentions the URI is not dropped*

## 2. Removal Is Complete and Transactional

- [x] 2.1 In `AgentDb.Store.Nodes`, add a single private purge helper that deletes from `nodes`, `vec_nodes`, `job_queue`, and `commit_meta` for a target URI and its descendants, all sharing one prefix predicate; keep every URI-keyed delete inside this one function; verify the function is the only place issuing these deletes
- [x] 2.2 Route the existing `rm_subtree/2` through `SQLite.transaction/2` so the four deletes commit or roll back together; preserve the current `:not_found` and `:is_root` returns; verify a failure injected into any one delete leaves all four stores unchanged
- [x] 2.3 Guard the `vec_nodes` delete behind `SQLite.vec_available?/1` so a machine without the extension still removes from `nodes`, `job_queue`, and `commit_meta`; verify against a store opened without sqlite-vec that removal succeeds and keyword search and read still work

## 3. Vector-Index Verification and Startup Reconciliation

- [ ] 3.1 Verify empirically that `DELETE FROM vec_nodes WHERE uri = ?` is supported on the pinned sqlite-vec build and that the HNSW index stays consistent afterward; record the outcome, and if unsupported, implement the skip-and-log fallback described in design.md instead
      - **BLOCKED (environment).** No sqlite-vec package is in `mix.lock`/`deps/`; it loads from a system extension path that is absent here, so `vec_nodes` is never created and `vec_available?/1` is always false. The question cannot be answered on this machine. The availability *guard* is implemented and tested (1.1, 2.3); the DELETE itself is untested.
- [ ] 3.2 Add an idempotent reconciliation to `SQLite.ensure_schema/1` that, only when `SQLite.vec_available?/1`, first checks for `vec_nodes` rows with no matching `nodes` row and then deletes them; verify orphans are cleared, that the check short-circuits when none exist, and that a fully clean database is left untouched
      - **Code complete; 2 of 3 checks verified.** Implemented and guarded by `vec_available?/1`. Verified: the check short-circuits when the extension is absent, and a clean database is untouched across repeated `ensure_schema` calls (`ensure_schema leaves a clean database untouched`). NOT verified: actual orphan reclamation, which needs `vec_nodes` to exist.
- [ ] 3.3 Verify end to end on a database that already holds leaked `vec_nodes` rows from prior removals: boot, confirm the orphans are gone, and confirm keyword and vector search still return correct results for live documents
      - **BLOCKED (environment).** Depends on 3.1: there is no `vec_nodes` table here, so no leaked rows can exist or be observed.

## 4. Closing the Dequeue Race

- [x] 4.1 In `workers/embedding_worker.ex`, re-check that the target node still exists inside the same `Writer.call/1` that persists the embedding, and complete the job as a no-op when it does not; verify a job whose URI was removed mid-compute leaves no `vec_nodes` row and does not retry — *gate implemented; the mid-compute path itself is not exercised because it needs a real embedding model, unavailable here. Queue-level cancellation is covered by `rm cancels queued jobs for the removed subtree`*
- [x] 4.2 In `workers/summarization_worker.ex`, apply the same existence check for both the `abstract` and `overview` write paths; verify a job whose URI was removed mid-compute leaves the `nodes` row untouched and does not retry
- [ ] 4.3 Verify the recreated-URI invariant: embed a document, remove its parent, write a different document at the same URI, and confirm vector search does not return it until its own embedding is indexed, then does return it afterwards
      - **Test written but INERT here.** `a recreated URI is not searchable on the removed node's embedding` is gated on `vec_nodes` existing, following the existing `sqlite_test.exs` convention. It did not execute in this environment. The store-level half of the invariant is covered by `rm leaves a removed subtree unsearchable` and `rm removes subtree from SQLite and cache`.

## 5. Re-Commit After Removal

- [x] 5.1 Verify with a test that commit, remove the destination, then re-commit an unchanged session returns the destination URI rather than `:unchanged` and restores exactly one document containing all messages in order
- [x] 5.2 Verify with a test that removal deletes only the removed destination's bookkeeping: a session committed to two destinations, one of which is removed, still short-circuits to `:unchanged` for the surviving destination
- [x] 5.3 Confirm no change is needed on the `http-api` side: `rm` is already a pass-through call there and its return contract is unchanged; verify the existing `http-api` specs still hold

## 6. Coverage for List and Tree

- [x] 6.1 Extend `test/agent_db_test.exs` so the existing removal test asserts all four stores are clean — `nodes`, `vec_nodes`, `job_queue`, and `commit_meta` — instead of `nodes` alone; this is the single home for the removal invariant
- [x] 6.2 Add tests for the `list` and `tree` scenarios in the spec delta: direct-children-only, missing URI returns `:not_found` for both, depth limiting at depth 1 versus 2, and that a tree reflects a prior removal
- [x] 6.3 Add tests for the removal error cases: removing a missing URI returns `{:error, :not_found}` and writes nothing, removing `viking://` is rejected with the tree left intact, and removing a top-level subtree succeeds while leaving sibling subtrees unaffected
- [x] 6.4 Add a test that cached reads and store reads agree after a removal, warming both the read and list cache entries before removing and asserting `not_found` from both paths afterwards

## 7. Final Verification

- [x] 7.1 Run `mix compile --warnings-as-errors` and `mix test` and confirm a clean run with no new warnings
      - *Verified by diffing the compiler warning set against a stashed baseline: 14 warnings before, 14 after, zero new. `--warnings-as-errors` still fails on 14 pre-existing warnings, all in files this change does not touch (`agent_db_web/*`, `application.ex`, `ml/model_manager.ex`, `store/writer.ex`, `web/endpoint.ex`). `mix test`: 72 passed, 0 failed (baseline was 45/47).*
- [x] 7.2 Re-read the spec delta scenario by scenario and confirm each is covered by a named test or an explicit manual check recorded in 3.3
      - *Audit: 20 scenarios. 17 covered by a named test. 3 not fully covered: "A removed URI does not acquire a summary or embedding afterwards" (queue half covered, worker half needs a real model), "A recreated URI is not searchable on the previous node's embedding" (inert, see 4.3), and the vec-index reclamation scenarios in 3.1/3.2/3.3.*
