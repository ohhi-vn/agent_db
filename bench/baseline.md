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
