# Proposal

## Why

The store reports far more health than it has. Its telemetry collapses every job
outcome into "ok", its recent-error list shows the reason `error` for every
failure, and its console renders a failed read as an empty result — so an
operator watching the console cannot tell a quiet store from a broken one. Under
neath, the memory subsystem silently drops facts an agent recorded: the same
value written at two different URIs leaves the second one invisible to recall,
and a candidate overwrites the document of the active belief it disagrees with.
Both classes of defect were confirmed by running the code, not by reading it.

This change makes the store's own reporting trustworthy and its memory
semantics correct, then uses those corrections to add the memory capabilities
an agent actually needs and to give the console the stats it currently
computes and throws away.

## What Changes

### Memory correctness (confirmed defects)

- **A repeated value no longer hides a distinct URI.** The duplicate check is
  scoped to the URI being written. Recording the same value at two different
  URIs today leaves the second one a *candidate* — invisible to default
  recall, with no error, no log at warning level, and no way for the caller to
  learn it happened. Verified: after recording `zzz unique value aaa` at
  `…/profile/probe-a` and then at `…/profile/probe-b`, recall of `probe-b`
  returned `{:ok, []}`.
- **A candidate no longer overwrites the active belief's document.** Today
  `put_memory` writes the candidate's value into the node document while the
  active assertion still holds the old value, so `read/1` returns the candidate
  and `recall/1` returns nothing — the document and the assertion disagree.
  A candidate now leaves the active document in place.
- **Recall reports the type of each row, not the type of the scope.** Recalling
  the whole memories root returns `type: nil` for every entry, because the
  type is derived from the requested scope rather than from the row's own URI.
- **A malformed recall URI returns an error instead of raising.**
  `recall(uri: "not-a-uri")` raises `Protocol.UndefinedError` from
  `Enum.take/2` on the atom `:invalid_uri`; the same path crashes
  `mix agent_db.recall notaschi`. It now reports `{:error, :invalid_uri}`.
- **A memory write is atomic with its embedding enqueue.** The document write,
  the assertion write, and the embed job are currently three separate
  operations, so a failure between them leaves a memory that is durable but
  unsearchable, or a document with no assertion behind it.
- **Memory recall is bounded.** `recall/1` accepts `:top_k` and applies it in
  storage, like `search/2` already does. Today the limit is a hardcoded
  `LIMIT 500` with no way to ask for fewer and no signal that the set was
  truncated.

### Observability that reflects what happened (confirmed defects)

- **Job outcomes keep their meaning.** `:stored`, `:discarded`, `:deferred`,
  and `:failed` all normalize to `:ok` on the way to telemetry, so a failed job
  is counted as a success and `outcome="error"` never fires for a job. The
  outcome taxonomy now distinguishes them, and the metric dimension is bounded
  to a fixed set.
- **Errors carry their classified reason.** The `:reason` metadata is dropped
  before emission, so every entry in the console's recent-failures list reads
  `error`. The classified reason now survives to the sink, and it is the same
  code the transport returns.
- **The sink keeps latency, not just counts.** Only failures currently retain
  `duration_ms`; successful operations record nothing. The sink now keeps a
  bounded per-operation latency summary, so p50/p95/p99 and error rate are
  answerable — the queries `guides/MONITORING.md` already recommends but which
  have no data behind them today.
- **The `code` dimension is populated.** The taxonomy specifies
  `(operation, kind, outcome, code)`; no event carries a `code` today.

### Console that shows the store's real state

- **The console reports per-operation statistics.** `operation_stats/0` exists,
  is exposed through the web context, and is called by nothing. The overview
  page now renders it.
- **Coverage stops under-reporting.** `hex_locked` is computed by
  `HexDocs.coverage/0` and never merged into the facade's response, so the
  storage page always renders "0 of 0 covered". The same merge drops
  `reclaimable`, `needs_backfill`, and `active_dim` — the drift signals the
  storage page exists to show.
- **A failed read is not an empty store.** Seven error branches turn a failed
  read into zeros or an empty list, so a broken store presents as a healthy,
  empty one. They now render the classified reason.
- **An unreadable queue is not an idle queue.** `queue_detail/0` computes an
  `available` flag that is never rendered.
- **The sidebar toggle works.** The control is a static button with no
  handler, so the sidebar cannot be hidden — the console spec already requires
  that it can.
- **The pages load once.** Every page loads twice on mount (once from
  `connect/2`, once from `handle_params/3`), which on a remote provider means
  four blocking health probes before the first paint.
- **The skills layer view stops being an N+1.** Expanding the LLM layer view
  issues ~5 reads per skill, for up to 50 skills, on every refresh.

### Performance

- **Cache invalidation stops scanning whole tables.** Removing a subtree
  enumerates every key of both cache tables and filters in Elixir, which the
  context-store spec explicitly forbids on the hot path.
- **The cache is bounded and observable.** It has no TTL and no size limit, so
  it grows for the process lifetime, and it reports no hit rate.
- **Subtree predicates use an index.** `(uri = ?1 OR uri LIKE ?2 ESCAPE '\')`
  defeats the primary-key index and scans the whole table for every subtree
  count, enable, and group operation.
- **Writes are not silently truncated by a default timeout.** Every writer
  call uses `GenServer.call`'s 5-second default, so a slow write exits the
  caller while the write still lands.
- **Memory recall stops re-embedding the whole candidate set.** Recall embeds
  up to 500 candidate values on every call, ignoring the vectors already
  stored alongside each memory.
- **Conflict detection stops being quadratic in Elixir.** It issues one
  query per memory and decompresses both float blobs again for every pair.
- **A memory write stops leaking the embed job's result.** The enqueue result
  is discarded, so a memory can be recorded "successfully" and never become
  vector-searchable.

### Agent-facing memory capabilities

- **Importance participates in ranking.** It is recorded, validated, and
  exposed, and read by nothing that ranks.
- **Recall can be scoped by source.** `source` is stored and never filterable,
  so an agent cannot ask "what did this session teach me".
- **The candidate queue is visible.** Promotion, rejection, and the pending
  list exist on the facade but are not exposed over MCP, so an agent that
  records a candidate cannot promote it.
- **Memory statistics are reported.** There is no count of memories, no
  candidate backlog, and no per-type breakdown anywhere an operator can read.
- **A memory is a document of the tree.** The console has no memory surface at
  all, so an operator cannot see what the agent has learned.

## Capabilities

### New Capabilities

- `agent-memory`: The agent-facing contract for durable memory — bounded and
  source-scoped recall, importance-weighted ranking, the candidate lifecycle
  an agent can drive end to end, and the statistics that describe what the
  agent has learned.

### Modified Capabilities

- `memory`: Correct record/revise semantics — a repeated value no longer hides
  a distinct URI, a candidate no longer overwrites the active belief's
  document, recall reports each row's own type, a malformed scope is an error
  rather than a raise, and a memory write is atomic with its embed job.
- `runtime-observability`: Job outcomes keep their meaning, errors carry their
  classified reason, the sink keeps bounded latency so percentiles and error
  rate are answerable, and the `code` dimension is populated.
- `admin-dashboard`: The console renders per-operation statistics, complete
  index coverage, unavailable-versus-empty states, a working sidebar toggle,
  and single-pass page loads.
- `context-store`: The read cache is bounded, observable, and invalidated
  without whole-table scans; subtree predicates are index-backed; and writes
  are not silently abandoned at a default timeout.

## Impact

**Code**

- `lib/agent_db/application/memories.ex` — record/revise gating, scope
  validation, type derivation, recall bounding, atomic write, embed enqueue.
- `lib/agent_db/store/memories.ex` — value-equality scoping, bounded recall
  query, `source` filter, batched conflict vectors.
- `lib/agent_db/adapters/sqlite.ex` — atomic memory write, single conflict
  query, vector reuse in recall.
- `lib/agent_db/observability.ex`, `lib/agent_db/observability/sink.ex` —
  outcome taxonomy, reason propagation, latency retention, `code` dimension.
- `lib/agent_db/job_queue.ex`, `lib/agent_db/workers/job_worker.ex` — job
  outcome reporting.
- `lib/agent_db/cache.ex` — bounded cache, hit/miss counters, index-free
  invalidation.
- `lib/agent_db/store/nodes.ex`, `lib/agent_db/store/sqlite.ex` — subtree
  predicates and the supporting indexes.
- `lib/agent_db/store/writer.ex`, `lib/agent_db/store/reader.ex` — write
  timeouts and busy-retry backoff.
- `lib/agent_db/agent_db.ex`, `lib/agent_db/core/storage.ex` — facade
  additions and the storage port contract.
- `lib/agent_db_web/live/admin*.ex`, `lib/agent_db_web/context.ex` —
  console surfaces and the new memory page.
- `lib/agent_db_web/mcp.ex` — memory tools for the candidate lifecycle.
- `lib/agent_db/application/status.ex` — coverage merge and availability
  flags.

**Compatibility**

- `recall/1` gains an optional `:top_k`; existing calls are unaffected.
- The telemetry `outcome` dimension gains values. Consumers that switch on
  `:ok`/`:error` must also handle `:deferred`, `:failed`, and `:discarded`.
  This is the one **BREAKING** change in this proposal.
- The `memory_meta` table gains no new columns; the candidate gate's behavior
  changes without a schema migration.
- MCP gains tools; it removes none.

**Not in scope**

- Multi-user or per-tenant memory namespaces — the memories root stays
  `viking://user/memories`.
- Model-backed consolidation or reflection. The store stays model-free on the
  memory write path.
- Replacing substring search with FTS5. Trigram or token semantics would
  change what a keyword search matches, which is a separate change.
- Sharding the writer or adding a statement cache. Both are worth doing and
  both are larger than the defects fixed here.
