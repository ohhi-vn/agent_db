## Context

Greenfield repo: no code exists yet. The change creates the first Mix project `agent_db`. See proposal.md for motivation. Constraints agreed with the user: Elixir/OTP application logic; native SQLite driver (exqlite NIF) accepted as the single non-pure-Elixir boundary; SQLite for persistence; ETS for in-memory caches; fully offline with caller-supplied content and keyword search (no LLM, no embeddings, no network).

## Goals / Non-Goals

**Goals:**
- Embedded library: host app starts `AgentDb.Application` and calls a small public API.
- SQLite as single source of truth; ETS strictly a disposable read cache that never serves data newer than disk.
- Offline by construction: no network calls in any code path.

**Non-Goals:**
- Vector search, LLM summarization, HTTP server, multi-node (see proposal Non-Goals).

## Decisions

### D1. exqlite over Ecto/ecto_sqlite3
Direct `Exqlite.Sqlite3` calls. Rationale: the store has ~6 tables with fixed access patterns; Ecto adds a schema layer, migrations machinery, and a pool we do not need. Alternative considered: `ecto_sqlite3` - rejected for dependency weight and because schemaless direct SQL keeps the storage layer auditable.

### D2. Single writer process serializes all SQLite writes
One `GenServer` owns the SQLite connection; all writes go through it (GenServer.call). Readers use their own connections. SQLite permits multiple readers + one writer; exqlite notes simultaneous writes are unsupported. Alternative: busy_timeout with raw concurrent connections - rejected: racy, error-prone retry logic for zero benefit at this scale.

### D3. ETS cache design
Per-node named ETS tables (`:set`, `read_concurrency: true`), owned by a dedicated cache-owner GenServer so they survive cache-helper crashes (`heir` on init). Two tables:
- `node_cache`: `{uri, %{content | :dir, abstract, overview, etag, cached_at}}` for node reads.
- `dir_cache`: `{parent_uri, MapSet of child names}` for listings.
Read path: ETS hit -> return; miss -> SQLite read -> fill ETS -> return. Writes: persist via writer, then invalidate/refresh the affected `uri`, its parent's `dir_cache` entry, and ancestors' `dir_cache` entries (child-count summaries may change). `ets` tables are rebuildable from SQLite at any time; on cache-owner restart, tables are recreated empty and repopulate lazily - correctness never depends on cache contents.

### D4. FTS5 optional, LIKE fallback mandatory
Search implemented as `LIKE` with escaped `%`/`_` and case-insensitive collation on `lower()`; FTS5 used only if the compiled SQLite has it (`SELECT fts5(?)` probe at startup); otherwise pure LIKE. Rationale: exqlite's bundled SQLite may vary; spec requires keyword search regardless.

### D5. URI validation and traversal safety
URIs parsed to segment lists; reject empty segments, `.`/`..`, backslashes, and control characters. `%`-encoding is preserved verbatim (no decode step) so cache keys and SQLite keys are byte-identical.

### D6. Idempotent session commit via content-hash check
Commit computes SHA-256 over the serialized message list; a metadata column stores the last-committed hash per (session, destination). Re-commit with unchanged hash is a no-op; with new messages it rewrites the destination document atomically (single SQLite transaction).

### D7. Cache-owner recovery on crash
Cache-owner GenServer traps nothing; on crash, supervisor restarts it and `init` recreates empty tables. In-flight readers may get cache misses (correct, just slower). No data loss possible since SQLite is authoritative.

### D8. Supervision tree
```
AgentDb.Application (one_for_one)
  AgentDb.Cache.Owner        # owns ETS tables; safe to crash/restart
  AgentDb.Store.Writer       # GenServer owning the single write connection
  AgentDb.Store.ReaderPool   # pool of N reader connections (N = schedulers_online)
```
Writer before readers is not load-bearing (readers are independent); `one_for_one` suffices. `init` runs schema DDL with `PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON`.

## Risks / Trade-offs

- [Single writer serializes writes] -> Acceptable for embedded single-node use; document as a known limit; batched writes within one call amortize.
- [ETS caches can go stale across external SQLite edits] -> Document: mutate only through the API; provide explicit cache clear.
- [FTS5 availability varies by SQLite build] -> LIKE fallback guaranteed by D4; FTS5 only an optimization.
- [LIKE search is O(n) over documents] -> Fine at target scale (thousands); FTS5 path mitigates when present.
- [Atom exhaustion from user input] -> URIs are never converted to atoms; segments stay binaries.
- [Long content in ETS bloats memory] -> Cache only nodes actually read; ETS is bounded by working set, not total DB size; no TTL needed because invalidation is event-driven on writes.

## Migration Plan

Greenfield: no migration. Rollback = remove the dependency; SQLite file is a single self-contained artifact that can be archived or deleted.

## Open Questions

None. Caller-supplied summaries, keyword search, and single-node scope were confirmed with the user.
