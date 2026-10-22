# Design

## Context

See `proposal.md` — Why. This section records only the technical facts that
constrain the approach.

**How the defects were established.** Every defect named in the proposal was
reproduced by running the code against a scratch database, not inferred by
reading it. The reproductions that shaped the design:

| Defect | Reproduction |
|---|---|
| Duplicate value hides a distinct URI | Record `zzz unique value aaa` at `…/profile/probe-a`, then at `…/profile/probe-b`; recall of `probe-b` returns `{:ok, []}` while `probe-a` returns the memory. |
| Candidate overwrites the active document | Record `prefers Elixir over Go` at `…/profile/probe-a`; read of `probe-a` returns the value while recall of `probe-a` returns `{:ok, []}`. |
| Type is `nil` under a root scope | Recall of `viking://user/memories` returns every entry with `type: nil`; recall of `…/preferences` returns `type: "preferences"`. |
| Malformed recall scope raises | `recall(uri: "not-a-uri")` raises `Protocol.UndefinedError` from `Enum.take/2` on the atom `:invalid_uri`; `mix agent_db.recall notaschi` crashes the same way. |
| Job outcomes collapse | `emit_job(:embed, :failed, …)` then `emit_job(:embed, :deferred, …)` produce sink counts `{:job, %{kind: :embed}, :ok} => 2`. |
| Sink reason is always `:error` | A production-path failure produces `reason: :error` in the sink's recent-error entry. |
| `hex_locked` never reaches the console | `hex_locked` appears only at `admin_components.ex:1038`, as a `Map.get(@coverage, :hex_locked, 0)` default. Nothing produces it. |
| Reclaim worker crashes on success | `Cache.invalidate_write(nil)` raises `FunctionClauseError`; the reclaim job's payload is `%{}`, so `job.payload["uri"]` is `nil`. |

**The SQL constraint that shapes the storage work.** The subtree predicate
`(uri = ?1 OR uri LIKE ?2 ESCAPE '\')` cannot use an index. SQLite's `LIKE`
optimization requires a prefix pattern *and* a collation that agrees with the
index; `ESCAPE` disqualifies it and the column's `BINARY` collation disagrees
with `LIKE`'s case-insensitive default. Measured plans on a 5 000-row store:

```
current:  SEARCH nodes USING INDEX idx_nodes_kind (kind=?)      -- full scan of doc rows
```

Three alternatives were measured against the same data:

| Approach | Plan | Semantics |
|---|---|---|
| `uri GLOB 'prefix/*'` | `SEARCH ... (uri>? AND uri<?)` — indexed | **Case-sensitive.** Changes behaviour: `LIKE 'Viking://…'` currently matches `viking://…`. |
| Byte range `uri >= p AND uri < upper` | `SEARCH ... (uri>? AND uri<?)` — indexed | Case-sensitive, and the upper bound needs byte-carry arithmetic to avoid over-matching (`char(1114111)` over-matches `…/10/`). |
| **`idx_nodes_uri_nocase` on `nodes(uri COLLATE NOCASE)`** | `MULTI-INDEX OR` — both branches indexed | **Unchanged.** `LIKE` stays case-insensitive; the index just gives the optimizer a case-insensitive ordering to range-scan. |

The third is chosen. It is the only one that fixes the plan without changing
what a query returns.

**The measurement facts that shape the observability work.** `Observability.emit_operation/4`
builds its metadata with `Map.take([:kind, :role])`, so `:reason` is dropped
before emission — that is why the sink's `reason` is always `:error`. The
worker's five outcomes (`:stored`, `:discarded`, `:deferred`, `:failed`,
`:error`) all reach `normalize_outcome/1`, which maps anything that is not
`:ok`/`:error` to `:ok`. The sink's `record/3` reads `duration_ms` only on the
error path, so successful operations retain no latency at all.

## Goals / Non-Goals

**Goals:**

- Every behaviour change in the specs is reachable from a test that fails
  before the change and passes after it.
- The store's own reporting is never worse than its reporting was — a new
  statistic that cannot be computed reports *unavailable*, never zero.
- Performance work is justified by a measured plan or a measured cost, and
  the measurement is recorded in the task that lands it.
- The memory subsystem's write path is atomic, so "recorded" means recorded.
- New public surface is minimal: one new capability's worth of facade
  functions, each of which the console or an agent actually calls.

**Non-Goals:**

- Rewriting the search stack. Keyword search stays substring-based. FTS5's
  token semantics cannot express a mid-word substring match, and SQLite's
  trigram tokenizer would change what a keyword search matches — a separate
  change with its own compatibility story.
- Splitting the writer or adding a prepared-statement cache. Both are real
  wins; both are larger than the defects fixed here.
- Making the memory subsystem model-backed. The store's promise is that
  recording a memory needs no model, and that promise survives this change.
- Giving the sink a sampling or export mechanism. It stays in-memory and
  bounded.

## Decisions

### 1. Scope the duplicate check to the URI being written

**Decision.** The duplicate-value gate compares against the value already
asserted *at the URI being written*, not against every active memory in the
root. A value that exists at a different URI does not, by itself, make the
new record a candidate.

**Why.** The gate exists to catch an agent writing the same fact twice at one
place. Applied to the whole root it catches something else: it makes the
second of two legitimately distinct facts invisible. The caller gets
`{:ok, uri}` and an empty recall, with no error and no warning — the store
accepted a fact and dropped it.

**Alternative considered.** Keep the root-wide check but report the demotion
in the return value. Rejected: it changes `{:ok, uri}` to a second shape and
every caller has to learn it, to fix a behaviour that has no specification
behind it. The `memory` spec's "Distinct URIs coexist" scenario already says
two memories at different URIs are both retrievable; the implementation
contradicts its own spec.

**Consequence.** The gate still fires when a caller re-writes the same URI
with the same value — which today produces a *second* candidate row on every
idempotent re-write (reproduced: two `remember/3` calls with the same value at
the same URI leave one candidate waiting). The corrected gate treats an
identical re-write as a no-op rather than a new candidate.

### 2. A candidate does not write the document

**Decision.** `put_memory/5` writes the node document only when the assertion
is active. A candidate is stored in `memory_meta` alone.

**Why.** `core/storage.ex` states the rule the code breaks: *"a URI never
holds a document no assertion backs."* Today a candidate overwrites the
document of the active belief it disagrees with, so `read/1` returns the
candidate and `recall/1` returns the active belief — the same URI answers
two different questions with two different values.

**Alternative considered.** Keep writing the document and make `read/1` prefer
the active assertion. Rejected: it splits the meaning of "the document at
this URI" across two places, and the document is what a search index and an
export read.

### 3. Derive the type from the row, not the scope

**Decision.** `entry/2` derives the type from `row.uri`.

**Why.** The type is a fact about where the memory is filed, and the row's own
URI is that fact. The scope is the question being asked, not the answer.
Today `opts[:uri] || row.uri` makes the answer depend on the question.

**Alternative considered.** Leave the field unset under a root scope. Rejected:
the type is already computed and exposed for narrower scopes; an inconsistent
field is worse than a consistently derived one.

### 4. Validate the scope before parsing it into segments

**Decision.** `validate_memory_scope/1` matches on the parse result
(`{:ok, segments}` / `{:error, :invalid_uri}`) instead of taking `elem/2` of a
tuple whose second element may be an atom.

**Why.** `elem(VikingURI.parse(uri), 1)` is `:invalid_uri` for a bad URI, and
`Enum.take(:invalid_uri, 2)` raises. A user-supplied URI is untrusted input
on a documented public path (`mix agent_db.recall`, the `memory_recall` MCP
tool). The `context-store` spec already says a malformed scope is "a
classified error and performs no writes"; today it is a crash.

**Alternative considered.** Catching the raise at the boundary. Rejected: it
leaves the invariant "a malformed scope raises somewhere inside the
application layer" in place for the next call site.

### 5. Make the memory write atomic with its embed job

**Decision.** The document write, the assertion write, and the embed-job
enqueue happen in one transaction on the writer connection.

**Why.** Three separate operations means three partial-failure states: a
document with no assertion, an assertion with no document, and — the one
reproduced — a memory that is durable but has no queued embed job, so it is
permanently invisible to vector search. The `context-store` spec already
requires this for document writes ("If persistence or enqueueing any required
job fails, the operation SHALL return an error and SHALL leave the prior
document state, cache state, and queue state unchanged"). Memory writes are
the same shape of operation and should carry the same guarantee.

**Alternative considered.** Enqueue first, then write. Rejected: a crash
between them leaves an orphan job for a document that does not exist — which
the worker already handles by discarding, but only after the job is claimed
and an attempt is spent.

### 6. Bound recall in storage, and report truncation

**Decision.** `recall/1` accepts `:top_k` (default and maximum documented),
applies it in the store's SQL `LIMIT`, and returns a truncation flag.

**Why.** `search/2` already has this contract and the code already knows how
to do it (`result_limit/1` refuses an out-of-range value rather than
silently defaulting). Memory recall has a hardcoded `LIMIT 500` with no way
to ask for fewer and no signal that the set was truncated, so an agent
reading memory back cannot bound its own context budget — which is the whole
point of asking for memory.

**Alternative considered.** Reuse `search/2`'s limit helper verbatim.
Rejected as-is: it reports `{:invalid_limit, value}` while `search/2` reports
`{:error, {:invalid_limit, value}}`; the memory path keeps its own shape but
adopts the refusal behaviour.

### 7. Use the stored vectors for recall ranking

**Decision.** Term recall loads the candidate rows' stored embedding vectors
from `vec_nodes_<dim>` and ranks against them, instead of embedding every
candidate value on the read path.

**Why.** The vectors are already there: `remember/3` enqueues an `:embed` job
whose result lands in `vec_nodes_<dim>` keyed by URI, and
`memory_conflict_pairs/1` already reads them. Recall ignores them and calls
`embed/1` with up to 501 texts on every term query — one `GenServer.call` to
the single `ModelManager` process, serializing against every other embedding
request in the system, including background jobs.

**Alternative considered.** Keep re-embedding but cap the candidate set
(embedding the query only and comparing against stored vectors — the same
thing). Rejected: it is the same change with extra steps.

**Fallback.** When the vectors are absent or their dimension differs from the
query's, recall falls back to confidence ordering and says semantic ranking
was not applied. This is the path a store without the sqlite-vec extension
always takes, so it must stay honest rather than silent.

### 8. Give the sink a bounded latency history

**Decision.** The sink keeps, per operation and outcome, a bounded ring of
duration samples alongside the existing counters, and exposes counts, latency
percentiles, and error rate.

**Why.** `guides/MONITORING.md` already tells operators to graph "Operation
latency by `operation` + `outcome` (p50, p95, p99)" and "Error rate by
`operation` + `outcome`". Neither is answerable today: the sink keeps
`duration_ms` only on the error path. The counters exist and are complete;
only the latency is missing.

**Alternative considered.** A fixed-bucket histogram (count per latency
bucket) instead of a ring of samples. Rejected for now: a ring of the last N
samples gives exact percentiles over a recent window and is simpler to
reason about; a histogram is the better shape if the window ever needs to be
longer than a ring.

**Bounding.** The ring is per `(operation, outcome)` with a fixed maximum
length, and the number of tracked operations is itself capped. Both bounds
are constants, not configuration — a diagnostic that can be configured out of
existence is not a diagnostic.

### 9. Keep the outcome dimension a fixed, documented set

**Decision.** The telemetry `outcome` dimension becomes
`:ok | :error | :deferred | :failed | :discarded`.

**Why.** The `runtime-observability` spec says "a deferred job remains
distinguishable from a failed job" and the `admin-dashboard` spec wants
failed jobs diagnosable. Today `:deferred` and `:failed` both become `:ok`,
so `increase(agent_db_job_total{outcome="error"}[5m]) > 10` — an alert the
monitoring guide recommends — can never fire.

**Alternative considered.** Collapse `:deferred` into `:ok` but keep
`:failed`. Rejected: deferral is the one outcome that means "try again later",
and an operator needs to tell a job that is waiting on a model from a job
that is waiting on nothing.

**This is the one breaking change in the change.** A consumer switching on
`:ok`/`:error` must handle the three new values.

### 10. Carry the classified reason to the sink and the metric

**Decision.** `emit_operation/4` and `emit_job/4` accept the classified
reason and include it as the `code` dimension.

**Why.** The `runtime-observability` spec names the dimension set as
"(operation, kind, outcome, code)" and no event carries a `code`. The reason
is available at every call site — `Observability.classify_reason/1` exists and
`error_tag/1` flattens to the transport code — but it is dropped at the
emission boundary. The console's recent-failures list renders
`entry.reason`, which is therefore always `:error`.

**Alternative considered.** Classify inside the sink. Rejected: the sink is
downstream of the log and the transport, and classifying in three places
invites the three to disagree — which is exactly what the spec's "the code
matches the classification recorded in telemetry for the same failure"
scenario forbids.

### 11. Report unavailable, never zero

**Decision.** Every console section that cannot read its data renders the
classified reason. The store's status functions carry an explicit
availability flag rather than substituting an empty map.

**Why.** Seven error branches currently turn a failed read into zeros or an
empty list: `status.ex` returns `%{documents: 0, …}` for a failed storage
read, so the documents page header reads "0 documents" for a store that may
hold millions. `queue_detail/0` computes an `available` flag that is never
rendered, so an unreadable queue presents as an idle one. The console spec
already requires that a store failure render a classified reason.

**Alternative considered.** Keep the zeros and add a warning banner.
Rejected: the per-section value is what an operator reads first, and a
warning banner is easy to miss on a page of numbers.

### 12. Merge the coverage the facade already computes

**Decision.** `AgentDb.index_coverage/0` merges `hex_locked` from
`HexDocs.coverage/0` and passes through `reclaimable`, `needs_backfill`, and
`active_dim` from the vector index statistics.

**Why.** `HexDocs.coverage/0` computes `locked:` and the facade drops it, so
the storage page always renders "0 of 0 covered" against a spec that requires
"how many Hex-doc packages locked by the project are indexed". The vector
drift signals are computed by the adapter and documented as the operator's
signal, and reach no page.

**Alternative considered.** Compute the merge in the console. Rejected: the
facade is the operator surface and already owns this merge; the console
should not be the place that assembles store answers.

### 13. Index the subtree predicate with a NOCASE index, not a rewrite

**Decision.** Add `idx_nodes_uri_nocase ON nodes(uri COLLATE NOCASE)` (and
the equivalent on `memory_meta`) and leave the SQL as it is.

**Why.** Measured (see Context): the current predicate plans as
`SEARCH nodes USING INDEX idx_nodes_kind (kind=?)` — a scan of every document
row — for every subtree count, enable, disable, and group operation. With the
NOCASE index the same predicate plans as `MULTI-INDEX OR` with both branches
indexed, and the results are unchanged, because `LIKE`'s case-insensitivity
is preserved.

**Alternatives considered and rejected.**
- *Rewrite to `GLOB`.* Indexed, but case-sensitive: `LIKE 'Viking://…'` would
  stop matching `viking://…`. That is a behaviour change nobody asked for.
- *Rewrite to a byte range.* Indexed, but case-sensitive, and the upper bound
  needs byte-carry arithmetic; `char(1114111)` was measured to over-match
  `…/10/` when scoping `…/1/`.
- *Rewrite the predicate to be case-sensitive.* It would make the exact-match
  branch and the descendant branch agree — they currently disagree, since
  `uri = ?` is case-sensitive and `uri LIKE ?` is not — but that is a
  separate correctness change, and the index fixes the performance problem
  without touching behaviour.

**Cost.** Two extra indexes, one on `nodes` and one on `memory_meta`, each
written on every row insert or update. Measured cost is not taken here; the
store's write volume does not justify more than two extra indexes to remove
a full table scan from every subtree operation.

### 14. Bound the cache, and count hits and misses

**Decision.** The node cache gets a maximum entry count with eviction of the
oldest entry, and the cache reports hits, misses, and hit rate.

**Why.** The cache has no TTL and no size limit, so it grows for the process
lifetime, holding the full L2 content of every document ever read. The
storage page surfaces the byte total, so an operator can see it growing and
cannot do anything about it. There is also no hit counter anywhere, so
"is the cache earning its memory?" is unanswerable.

**Alternative considered.** A TTL instead of a size cap. Rejected as the
primary mechanism: a TTL makes the eviction time unpredictable, so a hot
document can be evicted between two reads; a size cap with
least-recently-used eviction keeps the working set.

**On invalidation order.** The cache is invalidated *after* the write
commits. A reader that read the pre-write row and cached it after that
invalidation leaves a permanently stale entry. The fix is to invalidate
before the write as well as after, so the window in which a stale value can
be inserted is closed on both sides. The `context-store` spec already
requires that "cache state after a write SHALL equal the state a cold cache
would produce".

### 15. Invalidate subtree entries without scanning the cache

**Decision.** Subtree invalidation uses the same URI prefix logic the store
uses for subtree queries, against an index over cache keys, instead of
materialising every key of both tables and filtering in Elixir.

**Why.** `Cache.drop_beneath/1` does `:ets.select` over both tables and
filters in Elixir on every removal. The `context-store` spec names this
exactly: "Removal of a subtree and recent-error reads SHALL NOT scan entire
in-memory tables row by row on the hot path."

### 16. Give writes an explicit, bounded timeout

**Decision.** Writer calls take an explicit timeout, and a write that exceeds
it reports a retryable classified error rather than the caller's `GenServer`
exiting.

**Why.** Every writer call uses `GenServer.call`'s 5-second default, and no
call site passes one. A write that takes longer than that makes the *caller*
exit with `:timeout` while the write still completes — the caller is told the
write failed, and the write landed. The `context-store` spec already requires
that a contended write "returns a retryable classified error, not a crash".

**Alternative considered.** Raise the default timeout. Rejected: it delays
the failure rather than fixing the shape of it, and the shape is the problem
— the caller cannot tell "failed" from "may have landed".

### 17. Back off when the writer is busy

**Decision.** The busy-retry path waits with growing delay and gives the
caller a retryable classified error when the budget is exhausted.

**Why.** The retry is a single attempt with a fixed 10–50 ms sleep, and it
re-runs the whole callback. For the non-transactional write paths, a busy
error part-way through means the first half already committed, so the retry
runs it again — for a memory write, that inserts a second assertion row and
supersedes the first.

### 18. Bound the conflict read's work

**Decision.** The conflict read loads candidate vectors in one query and
compares them in bounded batches, and reports "not evaluable" when there are
too few vectors to compare.

**Why.** Today it issues one `SELECT embedding` per memory and computes
cosine similarity for every pair in Elixir, decompressing both float32 blobs
into lists on each comparison. At 500 memories that is 125 000 pairs and
roughly 190 million list operations on a read path.

### 19. Give the console a memories page, and one load per visit

**Decision.** A new `/admin/memories` page lists what the store holds as
memory and lets an operator promote, reject, or forget. Separately, the
console loads each page's sections once per visit instead of twice.

**Why.** The store has a memory subsystem with candidates and conflicts and
the console has no surface for it — an operator cannot see what the agent has
learned. And every page loads twice on mount: `connect/2` calls `load/1`, then
`handle_params/3` calls `load/1` again. On a remote provider that is four
blocking health probes before the first paint, because `model_status/0`
probes over HTTP with a 1.5-second timeout.

**Alternative considered.** Fix the double load by removing the `load/1` call
from `connect/2`. Rejected: `handle_params/3` does not run on the connected
mount in the same way it does on the initial one, so the call in `connect/2`
is what makes the first paint correct. The fix is to make the page's load
idempotent per visit rather than to remove one of the two calls.

### 20. Load the skills' layer view in one read

**Decision.** The layer view fetches the layers for the visible skills in one
store operation rather than one read per skill per layer.

**Why.** Expanding the LLM layer view calls `get_layers/1` per row, and each
call does five reads — so 50 skills is 250 reads and 250 telemetry events,
recomputed on every 30-second refresh and on every change event, whether or
not the operator is looking at the view.

### 21. Expose the candidate lifecycle to agents over MCP

**Decision.** MCP gains `memory_promote`, `memory_reject`, and
`memory_candidates`, and `memory_remember` accepts an `importance` option.

**Why.** The facade has `promote_memory/1`, `reject_memory_candidate/1`, and
`pending_memory_candidates/1`, and the MCP surface exposes none of them. An
agent that records a candidate has no way to promote it over the tool
surface — it must fall back to the CLI. `memory_remember`'s schema accepts
`confidence` and `source` but not `importance`, so an agent cannot set the
importance the ranking is about to start using.

### 22. Report memory statistics

**Decision.** The store reports counts per type, counts per status, the
review backlog, and how many memories have never been surfaced, computed by
the store rather than by loading every memory.

**Why.** `importance` is recorded, validated, and exposed, and read by
nothing that ranks. An operator cannot see how many memories exist, how many
are waiting for review, or how the store's memory is distributed across the
five types.

## Risks / Trade-offs

**[The telemetry `outcome` dimension gains values]** → Consumers that switch
exhaustively on `:ok`/`:error` will see unmatched values. This is called out as
the change's one breaking item in `proposal.md`. The mitigating choice is to
add the new values rather than to keep folding them into `:ok`, because a
failed job counted as a success is the defect being fixed.

**[A `COLLATE NOCASE` index on a `TEXT PRIMARY KEY` doubles the index
footprint for `nodes`]** → `nodes` gains a second index over the same column.
The alternative — rewriting the predicate — changes matching semantics. If
the index cost proves material, the rewrite can be revisited as its own
change with its own compatibility story.

**[Eviction changes what a read costs, so a hot document may be evicted
between two reads]** → The cache is documented as disposable: a miss is
answered from the store and produces the same value. Eviction changes
latency, not correctness. The hit rate the cache now reports is what tells an
operator whether the bound is set well.

**[Reusing stored vectors for recall ranking makes ranking depend on the
embedding job having run]** → A memory recorded moments ago has no vector
yet and would rank on confidence alone. This is why the fallback path is
explicit: recall reports that semantic ranking was not applied, rather than
silently returning a differently-ordered answer. A caller that needs
consistency across a write can wait for the embed job.

**[The atomic memory write holds the writer connection for the duration of
the enqueue]** → The writer already serialises every write in the system, so
this adds one enqueue's worth of latency to that queue rather than
introducing a new contention point.

**[Making the console report unavailable instead of zero could look like a
regression to an operator who reads "unavailable" as "broken"]** → That is
the point: today the same page reads "0 documents" for a store that may hold
millions, and an operator cannot tell that from an empty store. The failure
reason is shown alongside, so the operator sees *why* it is unavailable.

**[The duplicate-gate change makes a previously-candidate record active]**
→ A caller that recorded the same value at two URIs will now see two active
memories rather than one active and one candidate. This is what the
`memory` spec's "Distinct URIs coexist" scenario requires. The
cross-URI redundancy is still surfaced — by the existing conflict read, which
reports semantically similar pairs at distinct URIs.

**[Extending the sink to keep latency samples increases its memory
footprint]** → Bounded by a fixed ring length per operation and a fixed cap
on the number of tracked operations. Both are constants, not configuration.

**[The skills layer view refactor changes the shape of the data the view
renders]** → The view's output is unchanged; only the number of reads behind
it changes. The rendered markup is asserted by existing LiveView tests.

**[The MCP surface gains tools]** → Additive only. A client that lists tools
sees three more; a client that calls by name is unaffected.

**[Scope predicates remain case-insensitive on the descendant branch and
case-sensitive on the exact branch]** → Noted and left alone. It is a real
inconsistency, but changing it is a behaviour change beyond this change's
scope, and the index fix delivers the performance win without touching it.
Recorded here so it is not rediscovered as a surprise.

## Migration Plan

**Schema.** Two indexes are added: `idx_nodes_uri_nocase` on
`nodes(uri COLLATE NOCASE)` and `idx_memory_meta_uri_nocase` on
`memory_meta(uri COLLATE NOCASE)`. Both are created with
`CREATE INDEX IF NOT EXISTS` in the existing
`ensure_node_meta_indexes/1` hook, which already exists for exactly this
reason — an index on a column that a newer build added. Creating an index on
an existing table is a one-time O(rows) operation at startup; on a large
store this is a slow boot, so the index creation is placed where the other
idempotent index creation already runs and does not block serving.

**No data migration.** The `memory_meta` table gains no columns. The
behaviour change to the duplicate gate changes which rows are *active*, not
what is stored — existing candidate rows stay candidates and remain
promotable. A store that already accumulated duplicate-value candidates keeps
them; they become visible through the new review surface rather than
disappearing.

**Rollback.** The index creation is idempotent and its removal is a `DROP
INDEX`. Reverting the behaviour changes is a code revert; no stored state
depends on them, because no stored representation changed.

**Compatibility.** The one externally visible break is the telemetry `outcome`
dimension gaining `:deferred`, `:failed`, and `:discarded`. A consumer
reading `agent_db_job_total{outcome="error"}` starts seeing non-zero values
where it previously saw none — which is the intended effect, and an alert
that was previously dead begins to fire.

## Open Questions

None. Every decision that would change the specs, the approach, or the task
breakdown is resolved above.
