# Proposal

## Why

`agent_db` is a context *store*: it holds a URI-addressed tree, three content layers, and a vector index, and it can commit a session transcript into that tree. It has no *memory*. There is no `remember`, no `recall`, no `forget`, and no way to record a durable fact with any provenance. A caller that wants durable memory today has to hand-roll it: invent a URI convention, `write/3` a document, and keep its own index of what is current, how confident it is, and what it supersedes.

That gap is not hypothetical. The README already advertises `user/{id}/memories` as a namespace and the `context-store` spec already commits sessions to `viking://user/u1/memories/session-42` — so the tree has a memories *location* but nothing that gives those documents memory semantics. The result is the behaviour the OpenViking design is most concerned with avoiding: contradictions accumulate silently, because a revised fact overwrites its predecessor in `nodes` and the predecessor is simply gone, with nothing recording that it was ever believed or why it changed.

Separately, tracing the write path surfaced a defect: `commit_session/3` writes to SQLite and never invalidates the ETS read-through cache, so a read that follows a commit returns pre-commit content from a warm cache. That contradicts the `context-store` requirement *"Write path persists before cache"*, which states cache state after a write SHALL equal what a cold cache would produce. The memory API is built on the write path, so this is fixed here rather than left underneath it.

## What Changes

- **Add a `memory` capability.** A memory is a document in the tree at a caller-chosen URI under `viking://user/memories/`, carrying a type from a fixed taxonomy (`profile`, `preferences`, `entities`, `events`, `experiences`).
- **Add `remember/3`** to record a durable fact: value, type, optional confidence, optional source. Writing to a URI that already holds a memory revises that slot rather than creating a second one.
- **Add `recall/1`** to read memories back — by type, by subtree, or individually — returning only currently-active entries.
- **Add `forget/2`** to remove a memory and its provenance.
- **Add conflict resolution.** A revised memory does not erase its predecessor. The prior assertion is retained with a superseded status and a pointer to the assertion that replaced it, so a contradiction resolves to one active value while the history of the change stays inspectable.
- **Add a `memory_meta` sidecar table** carrying the structured per-assertion record (value, confidence, source, status, supersedes pointer, timestamps), alongside the human-readable value in `nodes`. This follows the existing `commit_meta` precedent and keeps `nodes` uniform, so search, embedding, and the job queue need no special-casing.
- **Extraction is the caller's, not the store's.** `remember/3` is itself the extraction decision: the caller is the agent, running in the same process, and already knows which facts are durable. There is no summarization model in this path, so the whole memory surface is deterministic and testable without model weights.
- **Memories embed but do not summarize.** `remember/3` enqueues an embedding job and no `:summarize_*` job; an L0 abstract and L1 overview of a one-line fact carry no information and cost a model load.
- **Fix `commit_session/3` cache invalidation** so a commit brings the read-through cache to the state a cold cache would produce.

Not in scope: skills, ingestion and parsing, document chunking, hierarchical retrieval, versioning of resources, and any permission or tenancy model. This change assumes single-tenant operation and adds no identity or scope enforcement.

## Capabilities

### New Capabilities

- `memory`: durable, typed, conflict-resolving memory over the context tree — taxonomy, `remember`/`recall`/`forget`, provenance, and supersession.

### Modified Capabilities

- `context-store`: requirement `Write path persists before cache` — the commit path SHALL bring the read-through cache to the state a cold cache would produce from SQLite, closing the gap where `commit_session/3` left a warm cache serving pre-commit content.

## Impact

- **Code:** `lib/agent_db/agent_db.ex` — `remember/3`, `recall/1`, `forget/2`, memory taxonomy and type validation, supersede handling, and cache invalidation in `persist_commit/4`. `lib/agent_db/store/sqlite.ex` — `memory_meta` DDL and indexes in `base_ddl/0`.
- **Reused unchanged:** `nodes`/`upsert_doc`, `enqueue_background_jobs`, `search/2` with `:scope`, `AgentDb.URI` parse/build/join, `Cache.Invalidate`, `commit_meta` as the sidecar precedent, and the existing `job_queue` + worker machinery. A memory is a node, so it is embedded, searchable, and tree-navigable without new machinery on those paths.
- **Behavior:** new public API on `AgentDb`. Existing tree operations are unchanged except that a commit now invalidates the cache for its destination, which is observable only as a commit no longer being masked by a stale read. No schema change to `nodes`; `memory_meta` is additive. No data migration — the tree has no existing memories to convert.
- **Recall works before inference is unblocked:** memories are keyword-searchable through the existing substring path, so `recall/1` is functional while vector search is still down pending `port-inference-to-bumblebee-serving`. Semantic recall arrives with that change and needs nothing further here.
- **Tests:** `remember`/`recall`/`forget` and supersession are deterministic and need no weights or network, so they are testable directly. The commit-path cache fix is testable by reading, committing, and reading again.
- **Dependencies:** none added.
