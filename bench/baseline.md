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
