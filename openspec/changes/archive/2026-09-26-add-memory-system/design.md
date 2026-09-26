# Design

## Context

See `proposal.md` — Why. The relevant current state:

- `nodes` is a single table (`uri` primary key, `kind` in `doc`/`dir`, `content`/`abstract`/`overview`). Every document in the tree is a row. There is no per-node metadata table.
- `commit_meta` is the existing precedent for structured metadata held *beside* a content row: `(session_id, destination_uri, content_hash, committed_at)`, used for commit idempotency.
- `write/3` persists, calls `Invalidate.on_write/1`, then enqueues `:embed` and, when the caller omitted them, `:summarize_abstract` and `:summarize_overview` (`agent_db.ex:51-80`).
- `persist_commit/4` bypasses both: it calls `Nodes.upsert_doc/6` inside `Writer.call/1` and neither invalidates the cache nor enqueues any job.
- `search/2` already accepts `:scope` as a URI prefix, which is what confines a recall to the memories root.
- Single-tenant: no caller identity exists anywhere, so the memory API takes no identity and enforces no scope.

## Goals / Non-Goals

**Goals:**
- A memory is a node. It is written, read, listed, tree-navigated, embedded, and keyword-searched by existing machinery, with no memory-specific branch on any of those paths.
- The URI is the identity of an assertion, so revision and coexistence need no separate concept.
- The whole memory surface is deterministic: no model load, no network, no model weights required to exercise it.
- Superseded history is retained and inspectable; forgetting genuinely removes the text.

**Non-Goals:**
- No extraction. The caller decides what is durable (see Decision 1).
- No `expires_at`. Nothing would read it, and an unread column is an unread promise.
- No change to `nodes`, to the write path's job policy for ordinary documents, or to `commit_session`'s output.
- No skills, ingestion, chunking, retrieval, versioning, or tenancy.

## Decisions

### 1. The caller is the extractor; there is no extraction step

**Decision**: `remember/3` records a memory the caller has already decided is durable. No summarization model participates in any memory operation.

**Rationale**: `agent_db` is a library linked into the agent's own VM, not a service sitting beside it. The agent is the component that knows which of its observations are durable, and it is already in a position to say so. OpenViking's session-commit pipeline runs LLM extraction because its store is external and must infer intent from a transcript; that inference step is redundant here, and paying for it would mean a memory write could fail, vary between runs, or block on a multi-minute cold model load.

The payoff is that the memory API is exercisable today. Vector and hybrid search are currently non-functional pending `port-inference-to-bumblebee-serving`; memories are still fully usable through the keyword path, and become semantically retrievable with no further work when that lands, because memories are nodes and nodes are already embedded.

**Alternatives considered**:
- *LLM extraction over session transcripts, run in a background worker* — rejected. Non-deterministic, so the memory specs could not be tested without weights; dependent on the inference path that is currently broken; and redundant with a caller that already knows.
- *Caller supplies a rule list, store applies it* — rejected. Same machinery as extraction with the intelligence still outside the store, plus a configuration surface nothing would validate.

### 2. The URI is the slot; `memory_meta` is the assertion log

**Decision**: A memory's URI names the thing being asserted. `nodes.content` holds the currently-active value. A new `memory_meta` table holds one row per assertion ever made at that URI:

```
  nodes                              memory_meta
  uri                     content     id │ uri │ value │ confidence │ source
  .../preferences/  <-- "Elixir"       1 │ ... │ "Go"  │    0.6     │ s-abc   status=superseded
                                             2 │ ... │ "Elixir"│  0.9     │ s-def   status=active
                                                                              supersedes=1
```

**Rationale**: Supersession requires an identity for the assertion that is stable across value changes; the URI supplies it for free. Recording to an occupied URI revises that slot; recording to a new URI adds a fact, so coexistence is expressed by URI choice rather than by a flag.

The sidecar table follows `commit_meta` rather than adding columns to `nodes`. That keeps `nodes` uniform — no memory-specific column, no migration on the hot table — so search, embedding, summarization, and tree navigation need no special-casing at all. It also splits the two access patterns cleanly: `nodes.content` is the human-readable, keyword-searchable value; `memory_meta` is the structured layer that answers "what is active, how confident, what superseded what."

**Alternatives considered**:
- *Add `confidence`/`source`/`status` columns to `nodes`* — rejected. Every existing query and every non-memory node would carry nullable memory columns, and the superseded chain does not fit a row-per-node shape without a second table anyway.
- *Store provenance as front-matter inside `nodes.content`* — rejected. Filtering by status or ordering by confidence would require parsing every candidate row, and it would make the value non-searchable as plain text.
- *Version the URI itself (`.../language@3`)* — rejected. Leaks history into the namespace, makes recall a scan rather than a lookup, and gives up the stable slot identity that supersession needs.

### 3. `forget/2` hard-deletes rather than tombstoning

**Decision**: Forgetting removes the value and every assertion row for that URI. Supersession, not forgetting, is what preserves history.

**Rationale**: A tombstone that keeps the text in `memory_meta` does not forget anything — the value is still in the database and still retrievable by anyone who queries the table. For a caller asking for removal, that is the wrong outcome. The audit chain that would justify a tombstone belongs to the supersede path, which is where it is actually wanted and is exercised on every revision.

**Alternatives considered**:
- *Tombstone with a `forgotten` status* — rejected. Retains the very text the caller asked to remove, and would need a filter on every read path to stay meaningful.
- *Soft-delete the node, keep `memory_meta`* — rejected. Same objection, and it additionally leaves a hole in tree navigation.

### 4. Memories embed but are not summarized

**Decision**: Recording a memory enqueues `:embed` only. It does not enqueue `:summarize_abstract` or `:summarize_overview`, even though `write/3` enqueues all three.

**Rationale**: L0 and L1 exist to compress a document large enough that reading it whole is wasteful. A memory is an atomic fact — `"prefers Elixir over Go"` — whose abstract and overview would necessarily restate the content and discard nothing. Generating them costs two model-dependent jobs and, on a cold cache, a model load, in exchange for text that is either empty or a truncation of the value already stored. `abstract/1` and `overview/1` on a memory fall back to the first-line and 280-character resolutions, which for a one-line memory is the value itself.

Embedding is a different matter: it is what makes a memory reachable by meaning rather than by substring, and it is the reason a memory becomes semantically retrievable at no additional cost once inference works.

**Alternatives considered**:
- *Full `write/3` job policy for consistency* — rejected. Consistency here means paying for a summary that cannot say anything the value does not.
- *No jobs at all, as `commit_session` currently does* — rejected. That path is a defect, not a precedent; a memory that is never embedded is invisible to vector search permanently.

### 5. The commit path's cache obligation is fixed here

**Decision**: `persist_commit/4` invalidates the read-through cache for its destination URI, and the `context-store` requirement is amended to state that the obligation covers every path writing document content rather than direct writes alone.

**Rationale**: The requirement already promises that cache state after a write equals what a cold cache would produce. `commit_session` violates it today, so a read following a commit returns pre-commit content. `remember/3` is built on the same write path, so leaving it would mean building the memory API on a path known to serve stale reads.

Folding it in rather than splitting it out keeps one reviewable unit and avoids landing memory on top of a known hole. It is independently verifiable — read, commit, read again — so it can be extracted later without difficulty if that is preferred.

**Alternatives considered**:
- *Separate change against `context-store`* — viable, and the natural home if the memory work is deprioritized. Rejected only because the defect sits directly under the new API.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Two write paths (`write/3`, `commit_session/3`) can drift again on cache or job policy | The amended requirement states the obligation for *every* content-writing path, so a future path is covered by the spec rather than by remembering to update one function. Worth a follow-up change to converge the two onto one internal writer. |
| `memory_meta` rows accumulate for heavily revised slots | One row per assertion, bounded in practice by how often a slot is revised. An index on `(uri, status)` keeps recall to a lookup. Retention policy is deliberately absent — nothing needs it yet. |
| Superseded values remain in the database and are reachable by a direct query of `memory_meta` | Intentional: supersession preserves history by design, and the public read path excludes superseded rows. Only `forget/2` removes text, and it removes all of it. |
| The memories root is a convention, not an enforced namespace | Nothing prevents a caller recording a memory outside it. Enforcing a reserved root would add a special case to the write path for a single-tenant store with one caller. `recall` scopes by the root it is given. |
| `forget/2` removes the audit chain for that slot | Accepted trade for genuine deletion. The chain that matters for understanding *why* a belief changed is retained on the supersede path, which every revision exercises. |
| Embedding jobs for memories fail while inference is broken | Same exposure as any other document. The job retries through the existing queue, and the memory is fully usable via keyword recall meanwhile. No memory operation depends on the job succeeding. |

## Migration Plan

1. Add `memory_meta` DDL and indexes to `base_ddl/0`. Additive, idempotent, no migration of existing data.
2. Fix `persist_commit/4` to invalidate the cache.
3. Add the memory API and taxonomy.
4. Add `memory_meta` reads/writes to the store layer.

Rollback: revert the change. `memory_meta` may be left in place harmlessly or dropped; no existing table or row is modified, so there is nothing to reverse in user data. The cache fix is independently revertible and has no persistent effect.

## Open Questions

- Should the memories root be configurable, or fixed at `viking://user/memories/`? Deferred: it is a single constant, and single-tenant has one caller. A configuration key is warranted only if a second namespace appears.
