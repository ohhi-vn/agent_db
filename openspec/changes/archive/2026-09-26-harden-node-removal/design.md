# Design

## Context

See proposal.md for motivation and `specs/context-store/spec.md` for the required behavior. The facts below are the current-state constraints that shape the approach.

**Writes are single-connection and serialized, but not transactional.** `AgentDb.Store.Writer` is a GenServer owning the only write connection; every mutation runs as `fun.(conn)` inside `handle_call` (`lib/agent_db/store/writer.ex:59-60`). `SQLite.exec_write/3` prepares, binds, steps, releases — there is no `BEGIN`/`COMMIT` anywhere in the codebase, so each statement autocommits independently. Nothing currently issues a multi-statement transaction, and no read-write path nests inside one.

**State keyed by URI lives in four places, and only one of them is cleaned up today.**

| Store | Keyed by URI | Cleaned by `rm/1` today |
| --- | --- | --- |
| `nodes` (`lib/agent_db/store/sqlite.ex:120-131`) | `uri` PK | yes — `Nodes.delete_subtree/2` |
| `vec_nodes` (`sqlite.ex:180-183`, `vec0` virtual table) | `uri` PK | **no** |
| `job_queue` (`sqlite.ex:162-173`) | `uri` inside a JSON `payload` | **no** |
| `commit_meta` (`sqlite.ex:152-160`) | `session_id` + `destination_uri` | **no** |

**The vector index is optional at runtime.** `load_vec_extension/1` probes `load_extension('vec0')` then `'sqlite_vec'`, and `try_create_vec_table/1` logs `"sqlite-vec extension not available, vector search disabled"` and continues (`sqlite.ex:186-190`). The table may therefore not exist on a given machine, and there is currently no public predicate for that.

**Orphan `vec_nodes` rows are invisible but not harmless.** `vector_search_impl/4` selects `FROM vec_nodes v JOIN nodes n ON n.uri = v.uri` (`lib/agent_db/agent_db.ex:302-308`), so orphans consume no result slots. That is exactly why the leak is silent: nothing surfaces it, and `LIMIT` is applied after the join.

**`JobQueue` can only cancel by job id, not by URI.** The public surface is `enqueue/2`, `dequeue/1`, `complete/1`, `fail/2`, `reset_running_jobs/0`, `stats/0` — there is no way to express "drop every job for this subtree".

**Dequeue and store are separated by expensive, non-transactional work.** Both workers call `ModelManager.embed/1` (embedding) or an LLM call (summarization) *outside* any transaction, then re-enter `Writer.call/2` to persist (`workers/embedding_worker.ex:78-97`, `workers/summarization_worker.ex:92-104`). `dequeue/1` has already flipped the row to `running` by then. So a job can be cancelled by URI and still complete its write unless the worker itself refuses to write.

## Goals / Non-Goals

**Goals:**
- Make removal a single all-or-nothing operation across every URI-keyed store, on the connection that already serializes all writes.
- Close the dequeue race that URI-level cancellation cannot close, by making each worker's write conditional on the node still existing.
- Make re-commit-after-removal work by treating `commit_meta` as part of the removed state rather than as independent bookkeeping.
- Reclaim rows already leaked into existing databases, without a schema migration.
- Keep every new `vec_nodes` interaction behind the existing optional-extension reality.

**Non-Goals:**
- No new public API. `rm/1`'s arity, return values, and error atoms (`:is_root`, `:not_found`) are unchanged.
- No non-recursive single-node delete. Removing a document always removes its subtree; a document has no children, so this only matters for directories, and splitting it is a separate API decision.
- No `move`/`rename`, no TTL/expiry, no node metadata columns, no `vec_nodes` compaction or `vec0` optimization pass.
- No schema migration. Table shapes are unchanged; only which rows are written and deleted changes.
- No `http-api` change. `rm` is already exposed there as a pass-through call, and its contract is unchanged.

## Decisions

### Removal runs as one explicit transaction on the writer connection

`rm/1` becomes: resolve segments and reject the root, then a single `Writer.call/1` that issues `BEGIN`, purges each URI-keyed store, and issues `COMMIT` — with `ROLLBACK` on any error.

*Why:* SQLite has no multi-table `DELETE`. Without a transaction, a failure partway through (for example `vec_nodes` rejecting a `DELETE` on a given sqlite-vec build) leaves `nodes` emptied but `job_queue` and `commit_meta` populated — strictly worse than today's behavior, which at least fails before touching anything. A transaction is the only way to satisfy "removal SHALL NOT be observable as partial".

*Alternative considered:* a temp table of doomed URIs plus `DELETE ... WHERE uri IN (SELECT ...)`. Rejected — it removes the need for a shared prefix predicate but not the need for a transaction, so it adds machinery without removing the constraint.

*Alternative considered:* leave the statements untransacted and make each independently idempotent. Rejected — idempotent retries do not help here, because the partial state is not a state any retry is scheduled to repair.

*Constraint this relies on:* the writer GenServer serializes all mutations, and no other code path opens a transaction, so `BEGIN` here cannot collide with an outer transaction. This invariant must hold for every future caller; the transaction is confined to one private helper in `Nodes` so there is a single place to audit.

### Cancellation by URI is necessary but not sufficient; workers also gate their own write

Two changes, because they close different races:

1. `JobQueue` gains a cancel-by-uri operation that removes queued jobs whose `payload` URI is the target or under the target prefix, covering both `pending` and `running` rows. It runs inside the removal transaction.
2. Both workers re-check that the target node still exists **inside the same `Writer.call/1` that persists their result**, and complete the job as a no-op if it does not.

*Why:* cancellation closes the common case (jobs still queued). It cannot close the case where a worker has already flipped the row to `running` and is inside an expensive `ModelManager.embed/1` or LLM call when the removal commits. That worker holds no transaction across its compute, so it will reach its write with a payload for a URI that no longer exists. The in-write existence check is what makes the invariant hold unconditionally; the `nodes` row is the authority because the removal transaction already removed it.

*Alternative considered:* have the worker delete-by-nothing and rely on `Nodes.update_updated_at/3` affecting zero rows. Rejected — it is true today for the summarization path but is an accidental side effect, not an enforced condition, and the embedding path would still insert its orphan row.

*Consequence accepted:* a worker caught mid-compute still pays for the model call and discards the result. That is wasted compute on a rare path, which is the correct trade against serving a stale embedding for a recreated URI.

### Removal deletes the destination's `commit_meta` rows

The purge includes `DELETE FROM commit_meta WHERE destination_uri = ? OR destination_uri LIKE ?prefix%`, inside the same transaction.

*Why:* this is the whole fix for the unrecoverable-commit defect. `persist_commit/4` decides `:unchanged` by matching `content_hash` (`agent_db.ex:471-478`); once the destination is gone, the hash row is stale bookkeeping about a document that no longer exists, and the next commit is a no-op that reports success. Deleting the bookkeeping restores the spec's actual intent — idempotency defined by converged state, so an unchanged session converges back onto a present document.

*Scope care:* the predicate is on `destination_uri` only, never on `session_id`. A session committed to several destinations loses bookkeeping for the removed one and keeps it for the rest, so an unrelated later commit is unaffected.

*Alternative considered:* keep `commit_meta` and make `persist_commit/4` verify the destination still exists before honoring `:unchanged`. Rejected — it fixes one caller while leaving the stale row to be re-discovered on every future commit, and it spreads removal semantics across two modules instead of one.

### `vec_nodes` is purged behind an explicit availability probe, and existing orphans are reclaimed at startup

A public `SQLite.vec_available?/1` predicate is added, reusing the `vec_version()` probe already used by `load_vec_extension/1`. The purge issues the `vec_nodes` delete only when the probe succeeds. Separately, `ensure_schema/1` gains an idempotent reconciliation that deletes `vec_nodes` rows having no matching `nodes` row.

*Why:* the availability predicate is needed regardless — any unconditional `DELETE FROM vec_nodes` would raise on a machine without the extension, turning a working keyword-only store into a failing one. The startup reconciliation exists because the leak is already in users' databases: without it, rows orphaned by every prior `rm` stay forever, and a node later recreated at an old deleted URI would inherit a stale embedding on exactly the path the new spec forbids. The predicate and the reconciliation are the same probe, so this adds one function, not a subsystem.

*Alternative considered:* lazily filter orphans at query time. Rejected — the `JOIN` already does that for search results; it does nothing for storage growth, which is the actual defect.

*Verification required:* whether `DELETE FROM vec_nodes WHERE uri = ?` is supported against the `vec0` table on the sqlite-vec build in use, and how it interacts with the HNSW index. If a build rejects it, the purge skips `vec_nodes`, still commits the rest, and logs; orphans then remain invisible to search via the existing `JOIN`, so the degradation is bounded and detectable. This is a build-compatibility question to settle during implementation, not a design assumption.

### The purge is one co-located function, not a registry

All URI-keyed deletes live together in a single private helper in `AgentDb.Store.Nodes`, sharing one prefix predicate built by the existing `like_escape/1`. They are written adjacently so that adding a table means editing one function.

*Why:* the spec requires that a future URI-keyed store cannot be silently forgotten. A registry, behaviour, or extension point would be more machinery than a store with four tables justifies; co-location plus a test that asserts all four stores agree is enough to make the omission visible.

*Note on `nodes` itself:* descendant removal there is guaranteed twice over — by the explicit `uri LIKE prefix%` predicate and by the `parent_uri` `ON DELETE CASCADE` foreign key with `PRAGMA foreign_keys` enabled (`sqlite.ex:14`, `sqlite.ex:130`). The prefix shape is retained because the other three tables need it, and keeping one predicate avoids a subtle divergence between what `nodes` and its siblings consider "in the subtree".

## Risks / Trade-offs

- **A sqlite-vec build may not support the required `vec_nodes` delete, or may not maintain the HNSW index on delete** → Probe availability first and skip the delete when the table is absent. Verify delete support against the pinned build early; if unsupported, fall back to leaving the orphan in place, log it once, and rely on the existing `JOIN` to keep it invisible. Search correctness is preserved either way; only reclamation is lost, and the startup reconciliation reports what it could not remove.
- **The explicit `BEGIN`/`COMMIT` is a new global invariant on the writer connection** → Keep it inside one private helper with a single call site. Any future code that needs a transaction spanning a `Writer.call/1` must compose with it rather than nest inside it. This is the one place where a careless future change could produce "cannot start a transaction within a transaction" at runtime, so it is called out in the code and covered by a test that performs a full removal.
- **A worker mid-`embed` or mid-LLM-call discards its result after paying for it** → Accepted. It affects only jobs already dequeued at the instant of removal, and the alternative is a stale embedding becoming searchable under a recreated URI, which is a correctness failure rather than a cost.
- **Deleting `commit_meta` changes what a re-commit reports for callers that were relying on the `:unchanged` short-circuit** → This is the intended fix, and it is the spec's stated contract, but it is externally observable: a caller that commits, removes, and re-commits now receives the destination URI instead of `:unchanged`. No `http-api` change is needed since both are successful returns of the same call.
- **Startup reconciliation runs a delete against a potentially large `vec_nodes` on every boot** → Make it conditional — run only when orphans are actually present, which a single `LEFT JOIN` existence check determines cheaply — and keep it inside the existing `ensure_schema` path so it cannot be forgotten.
- **Existing tests assert only that `nodes` is empty after `rm`** (`test/agent_db_test.exs:107-128`), which is why all three defects are invisible → Extend that test rather than adding a parallel one, and assert against all four stores so the invariant has a single home.

## Migration Plan

No schema migration and no data migration step. Deploy order is the normal one: the code, then the existing databases benefit from the startup reconciliation on their next boot.

**Rollback:** revert the code. The reconciliation only deletes rows that no longer correspond to any `nodes` row, so it cannot destroy live content, and the `commit_meta` deletion is likewise limited to destinations that were themselves removed. A rollback does not restore `commit_meta` rows deleted by a removal performed while the fix was live, but such rows describe documents that are already gone, and re-committing the session restores the document.

**Verification before considering this done:** a full `mix test` run, plus a manual check on a database that already contains leaked `vec_nodes` rows to confirm the reconciliation reports and clears them.
