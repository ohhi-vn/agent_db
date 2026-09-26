# Proposal

## Why

`AgentDb.rm/1` deletes a subtree from the `nodes` table and drops its cache entries, but the `context-store` capability has **no requirement or scenario covering deletion at all** — the behavior is implemented, untested against its real invariants, and in three places it is actively wrong. Because the store is the system of record for agent context, a removal that is not durably complete can silently resurrect deleted content or permanently lose committed context.

## What Changes

Three concrete defects, all verified against the current implementation:

1. **Committed context becomes permanently unrecoverable after removal.** `commit_meta` (keyed `session_id` + `destination_uri`) is never cleared by `rm/1`. `persist_commit/4` short-circuits to `{:ok, :unchanged}` when the stored `content_hash` matches. So `commit_session` → `rm` destination → `commit_session` with no new messages returns `:unchanged` and **never recreates the document**. The deletion is irreversible through the public API. This also contradicts the existing spec wording: idempotent commit means "converges on the same state", not "stays deleted".

2. **Removal is not durable: background jobs resurrect embeddings for deleted nodes.** `rm/1` leaves `job_queue` rows pending. The embedding worker (`lib/agent_db/workers/embedding_worker.ex:80-97`) then embeds content that no longer exists and `INSERT`s it into `vec_nodes`. The summarization worker does the equivalent `UPDATE nodes SET abstract/overview ...` against a missing row. Orphaned `vec_nodes` rows accumulate forever, and — worse — a node later re-created at the same URI inherits the *previous* node's embedding, so vector search returns that node scored against stale content until its own embedding job lands.

3. **Orphaned embeddings are never reclaimed.** `delete_subtree/2` (`lib/agent_db/store/nodes.ex:148-154`) touches only `nodes`. The `JOIN nodes` in `vector_search_impl` (`lib/agent_db/agent_db.ex:302-308`) hides orphans from results, so the leak is silent: `vec_nodes` grows without bound and is never reconciled.

Also specified for the first time, since they are observable behavior with no requirement behind them today:

- The documented `:is_root` rejection of `rm("viking://")` and `{:error, :not_found}` for a missing URI, including that a failed removal writes nothing.
- `list/1` and `tree/2` coverage beyond the single incidental "Directory listing reflects writes" scenario.
- The invariant that **every** table keyed by URI — `nodes`, `vec_nodes`, and queued jobs — agrees after a removal, extendable to any future URI-keyed table.

No new public API. `rm/1`'s signature and return contract are unchanged.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `context-store`: Adds a deletion requirement (recursive subtree removal, atomicity across all URI-keyed tables, cache invalidation, root/missing-URI error cases, and durability against in-flight background jobs), adds explicit `list`/`tree` scenarios, and tightens the session commit-idempotency requirement so that idempotency is defined by converged state rather than by a hash match alone.

## Impact

- **Code:** `lib/agent_db/agent_db.ex` (`rm/1`, `persist_rm/1`, `persist_commit/4`), `lib/agent_db/store/nodes.ex` (`rm_subtree/2`, `delete_subtree/2`), `lib/agent_db/job_queue.ex` (cancel-by-uri), `lib/agent_db/workers/embedding_worker.ex` and `summarization_worker.ex` (skip work for a URI that no longer exists), and `lib/agent_db/store/sqlite.ex` (optionally delete `vec_nodes` rows when the sqlite-vec extension is present).
- **Data:** `commit_meta` gains delete semantics. No schema migration is expected — this is a change to which rows are written and deleted, not to table shape. `vec_nodes` is a virtual table whose availability is already optional (`try_create_vec_table/1` tolerates failure), so every `vec_nodes` operation must stay conditional on the extension being loaded.
- **API surface:** none. `rm/1` keeps its current spec; only its guarantees are tightened.
- **Tests:** `test/agent_db_test.exs:107` asserts only that `nodes` has no leftover rows. It does not check `vec_nodes`, `job_queue`, or `commit_meta`, which is why all three defects are invisible today.
- **Dependencies:** none added.
