# Proposal

## Why

`/admin` is the operator's only view of the store, yet it hides information the store already holds and several of its signals are wrong: the document count reads zero, the model-status queue depth is a hardcoded `0`, and several console errors print raw terms. Separately, the codebase carries four modules that have outgrown their boundary, a near-verbatim tar/gzip codec in two modules, an implemented-but-unwired directory-listing cache that makes tree/list N+1, and a documented `top_k` that keyword search ignores. Making the console trustworthy and the module boundaries honest lowers total system complexity while fixing observable defects.

## What Changes

- **Enrich `/admin`** with operational information the store can already answer or can answer with a small additive extension, all through the existing operator facade:
  - Storage footprint: database and WAL file sizes, document/directory node counts, per-top-level-subtree counts.
  - Cache and memory: ETS cache entries and bytes per table; BEAM process/ETS/memory breakdown.
  - Queue detail: per-status counts, oldest pending age, and a failed-job list (kind, URI, attempts, last error).
  - Index coverage: vector index availability and row count, code-index document counts, locked-vs-indexed Hex docs.
  - Model operations: per-role load state, last load duration, in-flight inference count, and remote-provider health.
  - Runtime/liveness: node uptime, supervisor/process counts, and a bounded recent-errors list.
  - Fix the document count (currently always zero) and make an invalid page parameter render a bounded page rather than raising.
- **Targeted performance work** (spec-free by project convention; acceptance is measured against `bench/baseline.md`):
  - Wire the already-specified directory-listing cache into the list/tree read path to remove the per-node listing N+1.
  - Bound keyword search by the documented `:top_k` and push the bound toward storage.
  - Add `list`, `grep`, `find`, and a scaled-corpus scenario to the benchmark harness; retain only deltas that clear the documented run-to-run spread.
- **Refactor oversized modules** into the responsibilities already named by the architecture, without changing public contracts:
  - Extract the shared bounded tar/gzip codec (`AgentDb.Archive`) out of `Skills.Source` and `Application.DataTransfer`.
  - Bring session/commit SQL under `AgentDb.Store.Sessions` / `AgentDb.Store.Commits`, matching the existing `Store.Nodes`/`Store.Memories` pattern.
  - Extract model download/cache policy (`AgentDb.ML.ModelDownload`) and the EMLX→EXLA fallback into the backend layer.
  - Extract `AdminLive`'s render sections into function components; single-source the duplicated role map, `like_escape`, navigation validation, and transport-error rendering.
- **Code-health fixes** that align implementation with existing specs: route operational failures through `Observability.log`, remove dead code, fix `CodeIndex` callback reporting, refuse non-regular archive members, prune the stale lock entry, and correct `config/example.exs`.
- **BREAKING**: keyword search (`mode: :keyword`) now returns at most `:top_k` results (default 10), matching its documented contract; it previously returned every match. Facade signatures and result shapes are unchanged.

## Capabilities

### New Capabilities

- None — all work extends existing capabilities.

### Modified Capabilities

- `admin-dashboard`: ADDED requirements for the enriched operational surface (storage, cache/memory, queue detail, index coverage, model operations, runtime/liveness) and a MODIFIED document-count/pagination requirement.
- `context-store`: MODIFIED keyword-search requirement — results are bounded by the documented `:top_k` (default 10) rather than unbounded.
- `inference-providers`: MODIFIED provider-selection requirement — one authoritative configuration key selects the active provider, reported provider status reflects the provider actually serving inference, and provider health is reportable.

## Impact

- **Code:** `lib/agent_db_web/live/admin_live.ex` (+ new components module), `lib/agent_db_web/context.ex`, `lib/agent_db/application/status.ex`, `lib/agent_db/application/search.ex`, `lib/agent_db/application/documents.ex`, `lib/agent_db/cache.ex`, `lib/agent_db/adapters/sqlite.ex`, `lib/agent_db/store/*.ex`, `lib/agent_db/job_queue.ex`, `lib/agent_db/skills/source.ex`, `lib/agent_db/application/data_transfer.ex`, `lib/agent_db/ml/model_manager.ex` (+ `ModelDownload`, `Backend`), `lib/agent_db/runtime_context.ex`, `lib/agent_db/observability.ex`, `lib/agent_db/config.ex`, benchmark and test suites.
- **Storage:** one additive nullable column on `job_queue` for the last job error (safe, no data migration); a new storage-port callback family for footprint/counts.
- **Dependencies/configuration:** none added; `inference_provider` becomes the single provider key and `mix.lock` loses an unused entry.
- **Compatibility:** no `AgentDb` function signature or result shape changes. Keyword search becomes bounded as documented. Custom `Core.Storage` providers gain new optional/required callbacks, documented in `core/storage.ex`.
