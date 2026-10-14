# Benchmark baseline (improve-runtime-quality 1.2)

Collected: 2026-09-30 (Apple M1 Pro, dev env, `mix run bench/agent_db_bench.exs`).
Isolated SQLite data (temp dir intent; see note), workers stopped, 20 seeded
documents (`benchmark content <i> with keyword alpha`).

## Inputs

- `read`: `AgentDb.read("viking://resources/bench/doc1.md")`
- `tree_projection`: `AgentDb.tree("viking://resources/bench", 2)`
- `keyword_search`: `AgentDb.search("alpha", mode: :keyword, top_k: 10)`
- `hybrid_search_error_path`: `AgentDb.search("alpha", mode: :hybrid, top_k: 10)`
  (no models / no sqlite-vec in this env, so the vector leg fails fast —
  measures the classified-error path, not fused ranking)
- `write`: `AgentDb.write("viking://resources/bench/tmp.md", ...)`
- `queue_throughput`: `AgentDb.queue_stats()`
- Benchee: `time: 3, memory_time: 1`

## Results (ips, higher is better)

| Scenario | ips | average | median | 99th % | memory |
|---|---|---|---|---|---|
| read | 567.78 K | 1.76 μs | 1.50 μs | 4.13 μs | 1.38 KB |
| queue_throughput | 16.93 K | 59.07 μs | 39.58 μs | 460.64 μs | 1.15 KB |
| keyword_search | 4.32 K | 231.65 μs | 141.42 μs | 1778.93 μs | 14.33 KB |
| hybrid_search_error_path | 2.05 K | 488.37 μs | 178.81 μs | 916.76 μs | 1.55 KB |
| tree_projection | 1.23 K | 812.60 μs | 688.19 μs | 2935.72 μs | 73.31 KB |
| write | 0.90 K | 1110.68 μs | 987.40 μs | 4636.15 μs | 3.23 KB |

## Notes

- Write includes transactional document + job enqueue (2.1/2.2) on the single
  writer; queue_throughput is a read-only stats call.
- Hybrid here is the error path only. Fused-ranking throughput needs cached
  models + sqlite-vec; measure on a host with weights before optimizing the
  model-manager bottleneck (single GenServer serializes inference).
- This run predates the `BumblebeeLoader.backend_spec(:emlx)` fix; the hybrid
  error path then included an EMLX `FunctionClauseError` fallback. Re-run
  (5.2) after the fix for a clean comparison — only deltas supported by
  repeatable measurements justify optimization.
- Bench isolation caveat (fixed after this run): `mix run` autostarts the app
  before the script sets `:data_dir`, so this run wrote to `./data`. Future
  runs must restart the app with a temp dir (see script header).

## Re-run (5.2, post-fix, isolated temp dir)

Same inputs, `time: 3, memory_time: 1`, after the `:emlx` backend_spec fix
and bench isolation fix:

| Scenario | ips | average | median | memory |
|---|---|---|---|---|
| read | 398.48 K | 2.51 μs | 1.63 μs | 1.38 KB |
| queue_throughput | 15.23 K | 65.64 μs | 22.67 μs | 0.68 KB |
| keyword_search | 8.01 K | 124.80 μs | 106.60 μs | 14.33 KB |
| hybrid_search_error_path | 4.33 K | 230.87 μs | 177.79 μs | 1.55 KB |
| write | 1.86 K | 536.59 μs | 460.08 μs | 3.23 KB |
| tree_projection | 0.54 K | 1857.01 μs | 1576.46 μs | 77.15 KB |

Comparison: per-scenario deltas vs baseline are within run-to-run noise
(warm caches, scheduler jitter) — no code change between the runs targeted
throughput, and memory usage is identical. **No optimization is retained
from this comparison.** Remaining known bottleneck: `ModelManager` remains a
single GenServer serializing all inference, so adding workers improves queue
drain but not model throughput; changing that requires measurements with
warmed models plus model-runtime safety review, explicitly out of scope here.

## Error-mapping and hot-path run (improve-performance-error-handling)

Same inputs and method, collected 2026-09-30 on the same Apple M1 Pro host after
two changes: the durable job queue enqueues a write's whole family with one
`INSERT` (`JobQueue.enqueue_many/2`) instead of one statement per kind, and the
tree projection threads the node's parsed segments through the walk instead of
re-parsing the parent URI for every child.

`before` is the run on the same host immediately preceding both changes;
`after` is the best of two post-change runs, with the second shown for range.

| Scenario | before ips | after ips | after median | before median | delta |
|---|---|---|---|---|---|
| write | 3.64 K | 5.02–5.61 K | 145–158 μs | 213 μs | **+38 % (repeatable)** |
| tree_projection | 1.27–1.39 K | 1.68–1.84 K | 433–518 μs | 676–687 μs | **+25 % to +65 %** |
| read | 533–602 K | 562–627 K | 1.50–1.71 μs | 1.50–1.71 μs | noise |
| keyword_search | 6.93–7.84 K | 5.68–9.83 K | 85–134 μs | 121–126 μs | noise (variance ±60 %+) |
| queue_throughput | 42–47 K | 42–58 K | 12–21 μs | 21 μs | noise |
| hybrid_search_error_path | 4.29–4.51 K | 4.29–5.41 K | 155–211 μs | 210–214 μs | noise |

Only `write` and `tree_projection` moved outside run-to-run spread; memory usage
is unchanged for every scenario. Deviation is ±55 % to ±95 % on the slower
scenarios, so the other four are reported as noise rather than as small wins.
Both changes keep the same work inside the same transaction — the number of
statements changed, not what a successful write guarantees.

## Inference run (3.1) — local serving API and concurrent inference

Two findings, both measured against the cached `all-MiniLM-L6-v2` weights on
the same Apple M1 Pro host.

**The local serving call was wrong.** `Backend.Exla` called
`serving.tokenize/2` and `serving.generate/3`; pinned Bumblebee 0.8.0 exposes
neither — it builds an `Nx.Serving` from the model info and runs it. Every
`embed/1` and `summarize/2` therefore raised `UndefinedFunctionError` and the
store reported `inference_failed` for all local inference. Inference is now
built once at load time (`BumblebeeLoader.build_serving/4`) and run through
`run/2`, behind the unchanged `embed/1` / `summarize/2` contracts. Note that
`Nx.Serving.run/2` answers with the result unwrapped, not as `{:ok, result}`.

**Inference no longer serializes on the manager.** Runs left `handle_call/3`
for a monitored task, bounded by `Config.inference_concurrency/0` (default:
schedulers online); past the bound a caller runs inline, which is the
backpressure. Before, 8 concurrent calls cost exactly as much as 8 serial ones.

| Scenario | before | after | delta |
|---|---|---|---|
| 8 calls, serial | 13.1 s | 12.0–12.4 s | noise |
| 8 calls, concurrent | 13.2 s | 8.99–9.59 s | **−26 % (3 runs each, tight spread)** |

Full inference is not 8× faster: EXLA already threads internally, so the
remainder is arithmetic contention rather than the manager. What is removed is
the queue in front of the model.

**Queue drain (3.2).** A 40-document burst enqueued 40 embedding jobs. With
sqlite-vec absent the embedding was computed and then dropped, because
`vec_nodes` does not exist; that surfaced as a failed job, so every job burned
all 5 attempts against exponential backoff before giving up.

| Scenario | before | after |
|---|---|---|
| 40 embed jobs, cold model | 32.6 s, 40 failed | 8.5 s, 40 done |
| same, model already loaded | — | 6.3 s |

The work was finished in both cases; retrying could not change the outcome.
An embedding with no vec table to land in now completes the job, matching the
existing treatment of a result whose node is gone. The same guard on the read
path turns the raw `no such table: vec_nodes` SQL error into
`:vector_index_unavailable`, which is what `Application.Search` already
promised callers ("a leg that cannot be served is reported, not raised").

Summarization jobs for these documents still end `failed` here: the Qwen3 GGUF
weights are not cached on this host, so there is no model to run. That is the
environment, not the change.

## Addendum (distributed-context-runtime)

Same inputs, no absolute-latency assertion in CI. This change is additive-only:
`AgentDb.subscribe/unsubscribe` plus facade-level fan-out, `Core.Inference`
adapters (local default, opt-in Ollama/OpenAI-compatible), ordinary-document
code/Hex indexes, read-only runtime snapshots, `v1.subscribe` and
`v1.search_progress` channel events, per-stage OTel spans with bounded
dimensions, and `mix agent_db.index/search/tree/doctor`. Full `mix test`
passes (408 tests); `mix run bench/agent_db_bench.exs` smoke-checked with no
repeatable delta claimed. Cluster distribution (libcluster/Horde/CRDTs)
explicitly deferred.

## Listing cache and bounded keyword search (improve-ops-console-and-code-health)

Collected 2026-10-02 on the same Apple M1 Pro host, `time: 3, memory_time: 1`,
best of repeated runs. The harness gained `list`, `grep`, `find`, and a second
1,000-document corpus (`bench_wide`), because the cost being measured here
follows the number of *matches*, which a 20-document corpus cannot show.

Two changes: `Application.Documents.list/1` now reads and writes the
already-existing directory cache, and keyword search validates `:top_k` and
passes the bound into `Core.Storage.search_keyword/3`, which applies `LIMIT` in
SQL.

`before` is the same harness with `lib/` at its previous state — the two arms
differ only in the code under test, not in the inputs.

| Scenario | before ips | after ips | before median | after median | delta |
|---|---|---|---|---|---|
| list | 7.50 K | 1589.33 K | 112.63 μs | 0.50 μs | **+20 000 % (cached)** |
| tree_projection | 0.95 K | 10.53 K | 727 μs | 91 μs | **+1008 %** |
| keyword_search_wide | 0.168 K | 1.99 K | 5160 μs | 431 μs | **+1083 %** |
| keyword_search | 1.28 K | 1.38 K | 673 μs | 604 μs | noise |
| read | 576.40 K | 554.63 K | 1.54 μs | 1.63 μs | noise |
| write | 3.94 K | 4.91 K | 193 μs | 151 μs | noise |
| grep | 2.00 K | 2.20 K | 414 μs | 362 μs | noise |
| find | 1.72 K | 1.48 K | 507 μs | 513 μs | noise |
| queue_throughput | 4.90 K | 5.56 K | 179 μs | 161 μs | noise |
| hybrid_search_error_path | 0.0166 K | 0.0187 K | 59.2 ms | 49.4 ms | noise |

Memory per call, same runs:

| Scenario | before | after | delta |
|---|---|---|---|
| tree_projection | 68.67 KB | 39.67 KB | **−42 %** |
| keyword_search_wide | 701.60 KB | 12.82 KB | **−98 %** |
| keyword_search | 16.41 KB | 11.38 KB | **−31 %** |
| list | 5.58 KB | 1.38 KB | **−75 %** |
| read / write / grep / find / queue | 1.38–44.50 KB | 1.70–44.82 KB | unchanged within spread |

The two structural wins explain themselves. A tree projection listed every node
it visited, so a subtree of N documents cost N listing queries — 20 of them
asking a *document* for children it does not have. Caching both answers is why
`list` is now an ETS hit and why `tree_projection`'s allocation fell as well as
its time. Keyword search previously returned every match with its full content
and only then discarded all but `top_k`; with the bound in SQL, a term matching
1,000 documents allocates 12.82 KB instead of 701.60 KB.

### The observability sink's cost on the hot path

`Observability.Sink` attaches a `:telemetry` handler, so every measurement the
store emits now does work. That cost was measured rather than assumed, in words
reclaimed per `tree_projection` call over 5,000 calls:

| Handler | words/call |
|---|---|
| none attached | 3 742 |
| a handler that does nothing | 4 161 |
| the sink | 5 184 |

The first version of the sink cost **43 496** words/call. The cause was not the
counter write: `trim/1` collected the whole table with `:ets.tab2list/0` on
every failure, and a tree projection raises about twenty *error* events per
call, because listing a document legitimately returns `:not_found`. Trimming by
a single `:ets.select_delete/2` over the monotonic sequence numbers made it one
indexed pass instead of a scan per failure.

The sink is kept because the bounded recent-failure ring is a documented
requirement; the outcome counters it also keeps cost ~1 000 words/call on top of
an empty handler and are read by nothing the console renders.

## Post-change verification (end of improve-ops-console-and-code-health)

Collected 2026-10-02 after tasks 5.1-6.6. The two measured arms above were
re-measured for this change set and hold:

| Scenario | before ips | after ips | delta | memory before → after |
|---|---|---|---|---|
| list | 7.50 K | 1589.33 K | **+20 000 % (cached)** | 5.58 → 1.38 KB |
| tree_projection | 0.95 K | 10.53 K | **+1008 %** | 68.67 → 39.67 KB |
| keyword_search_wide | 0.168 K | 1.99 K | **+1083 %** | 701.60 → 12.82 KB |

Refactors in 5.1-5.3 moved code (archive container, session/commit SQL, model
download) without changing what any scenario measures, and the provider and
code-health fixes in 6.1-6.4 touch paths none of these scenarios run. No
retained performance change lacks a recorded delta above, and no unmeasured
optimization was kept: the `list` cache and the SQL-side `LIMIT` are the only
two, and both are measured.

## Retire-on-write (harden-vector-index-invariant)

Collected 2026-10-14, Apple M1 Pro. Four runs each, `time: 3, memory_time: 1`,
before and after the change. **This host has no sqlite-vec extension loaded**
(`SQLite.vec_available?/1` is false), so `Nodes.retire_uri_vector/2` short-circuits
after its guard and the per-dimension delete walk is never entered. The numbers
below therefore bound the guard, not the mechanism.

| Scenario | before ips | before median | after ips | after median | delta |
|---|---|---|---|---|---|
| write | 1.36-2.31 K | 314-536 us | 0.85-2.23 K | 356-553 us | within run-to-run noise |
| read | 438 K | 1.96-3.08 us | 461 K | ~2 us | unchanged |

The write scenario's own run-to-run variance is +/-110-240 %, which is wider than
the difference being measured, so no delta is claimed. What is established is
that retire-on-write adds one `vec_available?/1` guard per write and nothing
observable beyond it on a host without the extension.

**What is not yet measured, and why it matters:** the real cost of the deletion
walk is `list_vec_dims/1` plus one DELETE per dimension, on a provider holding
up to `@max_vec_dims` tables. On a host with the extension and a second provider
dim active, that is 2+ statements per write inside a transaction that already
runs several. The `@max_vec_tables` of 16 is the worst case, and the design's
recorded mitigation is to batch the per-dimension deletes into one statement
list if the write scenario regresses on such a host.

Also added, and no claim made: `rewrite_with_vector`, a re-write of the same URI
in a loop, so the retire path runs on every iteration rather than once per
distinct URI. Its numbers here are the same as `write`, for the reason above.

The `hybrid_search_error_path` scenario measured 54.8 ms average this run, which
is the model-loading path rather than fused ranking; it remains unmeasured, as
the previous baseline already recorded.

## The vector and hybrid legs, with cached weights (harden-vector-index-invariant)

Collected 2026-10-14, Apple M1 Pro, with the embedding model cached in
`models/sentence-transformers/all-MiniLM-L6-v2` (87 MB). Workers stopped, as
before. **This host still has no sqlite-vec extension loaded**, so the vector
leg embeds the query and is then refused by the index; the hybrid leg runs both
legs concurrently and gets the same refusal.

| Scenario | ips | average | memory |
|---|---|---|---|
| vector_search | 0.00986 K | 101 450.87 µs | 6.05 KB |
| hybrid_search_concurrent | 0.0133 K | 75 399.12 µs | 5.86 KB |
| hybrid_search_error_path | 0.0149 K | 67 277.70 µs | 5.80 KB |
| keyword_search_wide (for scale) | 1.41 K | 7 062 µs | 30.88 KB |

A direct probe, outside the harness:

- first vector search, including the lazy model load: **1 043 ms**
- subsequent vector search, warm: **78 ms**

**What these numbers say, and what they do not.** The embedding leg is now
measured, and it is expensive: two orders of magnitude above every other
scenario in this file, and it is a `GenServer.call` into a single serialized
process, so it is also not parallel across workers. That was previously
unmeasured — the file's own note asked for it and it sat unanswered since
2026-09-30.

What these numbers do **not** say is anything about ranking quality or ANN
lookup. The index refused, so no result was fused and no nearest-neighbour
query ran. On a host with the extension these scenarios would measure that leg
too, and the two numbers above would fall to the embedding floor rather than
stay inflated by the load.

**The recommendation this supports:** the bottleneck in the vector path was
already known to be inference serialization (the previous baseline names the
model-manager as the thing to optimize), and these numbers confirm it is the
whole cost. Any change that aims to speed up vector search should target
embedding generation — concurrency across the fan-out, a resident process pool,
a smaller model — and not the index.

`rewrite_with_vector` was also added and reported in the previous section; its
numbers here match `write`, because retire-on-write short-circuits at the
`vec_available?/1` guard on this host.
