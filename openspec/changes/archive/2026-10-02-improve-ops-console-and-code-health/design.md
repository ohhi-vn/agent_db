# Design

## Context

See `proposal.md` for motivation. Constraints that shape the approach:

- `AdminLive` must reach the store only through the `AgentDbWeb.Context` operator facade; `boundaries_test.exs` enforces that web modules name no store internals. `Application.Status` already composes model/queue/health for the facade.
- Durable per-URI facts go behind `AgentDb.Core.Storage` (the port implemented by `Adapters.SQLite`). Process-local runtime facts (ETS, BEAM memory, uptime) do not belong in the port.
- SQLite schema is created by idempotent `CREATE TABLE IF NOT EXISTS` DDL in `Store.SQLite.ensure_schema/1`; there is no migration framework. A new column on an existing table needs a guarded `ALTER TABLE`.
- The benchmark method in `bench/baseline.md` is authoritative: same-host, best of runs, retain only deltas beyond the documented run-to-run spread; performance is deliberately spec-free.
- `AgentDb.Cache` already implements `get_dir/2` and `put_dir/2` and already invalidates directory entries on every write/removal path; only the read path never uses them.

## Goals / Non-Goals

**Goals:**
- Make `/admin` show trustworthy operational state (footprint, cache/memory, queue detail, index coverage, model operations, runtime/liveness) sourced only through the facade.
- Remove the per-node listing N+1 in `list`/`tree` by wiring the existing directory cache.
- Bound keyword search work and results to the documented `:top_k`.
- Consolidate duplicated archive/codec and transport/role/validation logic; bring session/commit SQL and model download under the module boundaries the architecture already names.
- Make provider selection single-sourced and status truthful.

**Non-Goals:**
- No visual redesign, no new routes beyond additive `/admin/*` in the existing browser pipeline, no new authentication.
- No new external dependencies, no HTTP/WebSocket/MCP contract changes.
- No cluster/distribution work; no replacement of SQLite/ETS/queue architecture.
- No speculative performance micro-optimizations: only changes with a measured, repeatable delta are retained.
- Not implementing Hex-doc ingestion or a structural code-index query surface; only coverage reporting for what is stored.

## Decisions

### 1. New console data flows through facade → status → storage/runtime
Add `AgentDb` facade functions and `AgentDbWeb.Context` wrappers for: `storage_stats/0`, `cache_stats/0`, `runtime_snapshot/0`, `index_coverage/0`, `queue_detail/0`, and `observability_stats/0`. `Application.Status` composes them. `AdminLive` calls only `Context`.

*Alternatives:* reaching modules directly from the view (rejected — violates the enforced boundary and the console's documented contract); embedding everything in `model_status/0` (rejected — mixes responsibilities and bloats an existing contract).

### 2. Storage footprint and counts are a bounded storage-port extension
Add provider-neutral callbacks to `Core.Storage`:
- `stats/0` → `%{documents: n, directories: n, by_top_subtree: %{name => n}}`
- `document_count/1` (scope URI) for per-prefix counts, which the console's tree listing and `CodeIndex.coverage/0` both read
- `vector_index_stats/0` → `%{available: boolean, vectors: n}`
- `queue_detail/1` (bounded failure count) → `%{oldest_pending_ms: n | nil, failed: [%{id, kind, uri, attempts, last_error, failed_at}]}`

`Adapters.SQLite` implements them with indexed/bounded queries (`COUNT` by `kind`, prefix `LIKE` using the existing `Nodes.like_escape/1`, `MIN(scheduled_at)` over the status index, failed rows ordered by `updated_at` with a limit). Database/WAL byte sizes are filesystem facts the SQLite adapter reports too; a provider that cannot report them returns `nil` and the console shows "not reported".

*Alternatives:* a generic "describe everything" callback (rejected — vague ownership); exposing raw connections to the console (rejected — breaks the port).

### 3. Persist a job's last error with a guarded additive column
Background-job failures are currently logged then discarded; `JobQueue.fail/2` stores only status/attempts/schedule. Add a nullable `last_error TEXT` column to `job_queue`, with the error stored as a classified reason string (never raw content/URIs).

- Schema: in `ensure_schema/1`, after base DDL, read `PRAGMA table_info(job_queue)`; when `last_error` is absent, run `ALTER TABLE job_queue ADD COLUMN last_error TEXT`. Idempotent, additive, no data migration, backward compatible with older databases.
- Port: extend the failure callback from `fail_job/1` to `fail_job/2` (id, classified reason). This is a documented `Core.Storage` contract extension; custom providers must implement it.

*Alternatives:* stashing the error in the job payload (rejected — payload is written at enqueue and reused; mutating it is a hidden schema); a separate error table (rejected — more surface for one string).

### 4. A small observability sink owns recent errors and operation rates
Add a supervised `AgentDb.Observability.Sink` GenServer owning one ETS table. It attaches to the existing `:telemetry` events (`operation.stop`, `job.stop`, `model.stop`) and records bounded counters plus a bounded ring of recent error entries (operation/kind, classified reason, timestamp). `Observability` gains `recent_errors/0` and `operation_stats/0`; the dashboard reads them through the facade. Entries contain only classifications and timestamps — never URIs, content, prompts, users, or credentials.

To make the sink complete, operational failures currently logged with raw `Logger` are routed through `Observability.log/2` (which also emits structured fields), so every failure reaches the same funnel.

*Alternatives:* a custom `Logger` handler (rejected for now — captures noise and requires parsing text); storing errors in SQLite (rejected — runtime diagnostics, not durable state).

### 5. Runtime snapshot is extended, not duplicated
`AgentDb.RuntimeContext` gains `uptime_ms` (from `:erlang.statistics(:wall_clock)` or a recorded start time) and is exposed via `AgentDb.runtime_snapshot/0`. The dashboard uses the existing bounded snapshot for process/supervisor/ETS/memory and the sink for recent errors/rates. Truncation and read-only guarantees are unchanged.

### 6. Directory-listing cache on the read path
`Application.Documents.list/1` checks `Cache.get_dir/2` before storage and `Cache.put_dir/2` after, caching both `{:ok, names}` and `:not_found`. Existing invalidation (write, subtree removal, session commit, memory record/forget, skill import) already covers every path that changes membership, so correctness is preserved. This removes the per-node listing query in `project/3` (the N+1), because child listings become ETS hits after the first projection. Leaves store `:not_found`, which is correct and also cached.

*Alternatives:* skipping listing when `kind == :doc` (rejected — `ensure_parents/2` can create a `:doc` node with children, so this would change tree output); a single recursive subtree query (deferred — wider than needed and requires a new port method).

### 7. Keyword search is bounded and validates `:top_k`
`Application.Search.keyword/2` parses and validates `:top_k` (default 10, maximum 200, `{:error, {:invalid_limit, _}}` outside range), passes it to storage, and `Nodes.search/4` / `Adapters.SQLite.search_keyword/3` apply `LIMIT ?` in SQL. Result shape is unchanged; only the count becomes bounded as documented.

*Alternatives:* truncating after fetching all rows (rejected — leaves the unbounded scan and materialization); leaving it unbounded (rejected — contradicts the `search/2` contract and scales with the match set).

### 8. Shared archive codec and ownership consolidation
- New `AgentDb.Archive` owns bounded tar/gzip detection, listing, member extraction, and entry-type checks, parameterized by `max_bytes`; `Skills.Source` and `Application.DataTransfer` call it with their respective bounds. This also closes the data-portability gap by reusing one non-regular-entry refusal.
- New `AgentDb.Store.Sessions` and `AgentDb.Store.Commits` own the session/commit SQL currently inline in `Adapters.SQLite`, matching `Store.Nodes`/`Store.Memories`. One role mapper and one message reader live there; `DataTransfer`'s transfer validator stays its own trust boundary.
- New `AgentDb.ML.ModelDownload` owns download/cache/`.part`-rename policy; the EMLX→EXLA fallback moves to the backend layer (`Backend.load/2`), and the unused `model_info/0` callback is resolved.
- `AdminLive` render sections move to function components in `AgentDbWeb.AdminComponents`; the view keeps lifecycle, events, and data loading. `AdminLive` also stops printing `inspect(reason)` and uses `Observability.error_message/1`.

*Alternatives:* leaving duplication (rejected — two safety-critical copies drift); a full data-layer rewrite (rejected — larger than the problem).

### 9. Provider selection is single-sourced
`Runtime.inference/0` derives the adapter module from `Config.inference_provider/0` (`:local | :ollama | :openai_compatible | :custom`). An unknown value raises at startup. Each `Core.Inference` adapter reports its own provider kind; `Status.provider_kind/0` reads the resolved adapter instead of a parallel config key. `:inference_adapter` stops being a public selection key (tests set the provider key).

*Alternatives:* keeping both keys and syncing them (rejected — two sources of truth); dropping `inference_provider` and keeping the module key (rejected — the documented user-facing key is the provider name).

### 10. Quality fixes stay implementation-level
Dead code removal, `like_escape`/navigation-validation/`transport_error`/role-map consolidation, `CodeIndex.callback_names/2` returning the actual filtered callbacks, `config/example.exs` fixes, and `mix.lock` pruning are changes that make the implementation match existing specs; they need no new requirement text.

## Risks / Trade-offs

- [Custom storage providers break on new callbacks / `fail_job/2`] → Document the contract extension in `core/storage.ex`; new callbacks get sensible defaults where possible; `fail_job` is a required change called out in the proposal.
- [Additive `ALTER TABLE` on a large `job_queue`] → The column is nullable with no default rewrite; guarded by a `PRAGMA table_info` check; runs once at boot.
- [Dashboard count queries cost on large stores] → Use `kind` counts plus bounded prefix queries; label per-subtree/coverage counts as approximate; never run per-node queries.
- [Cached directory listings could go stale] → All membership-changing paths already invalidate ancestors; add a regression test, and keep the existing `:not_found` caching behavior explicit.
- [Keyword `top_k` bounding changes results for callers relying on unlimited output] → It matches the documented contract; called out as BREAKING; hybrid already bounded.
- [New observability sink adds a process and telemetry handler] → Small, supervised, bounded; reads are lock-free ETS; the sink is the only owner of the table.
- [Archive codec extraction touches security-critical parsing] → Keep behavior identical, parameterize only the bound, and lean on the existing thorough `source_test.exs` / `data_transfer_test.exs` coverage plus new shared-module tests.
- [Performance changes may not clear the noise floor] → Bench first; retain only repeatable deltas; otherwise keep the correctness/contract fixes and revert the optimization.

## Migration Plan

1. **Schema:** guarded additive `last_error` column; no data migration. Existing databases keep working; older code ignores the column.
2. **Config:** switch the provider key to `inference_provider`; update `docs/SETUP.md`, `config/example.exs`, and tests. Unknown values fail fast at startup (intended).
3. **Ordering:** land the facade/status/storage stats and observability sink first (additive), then the dashboard view, then refactors (each behind unchanged public contracts), then the keyword `top_k` behavior change and benchmark updates.
4. **Rollback:** revert the code; the extra nullable column and empty ETS table are harmless and require no cleanup. If a performance change regresses, revert only that change (baselines record the prior numbers).

## Open Questions

- None that change the specs, approach, or task breakdown. The `top_k` maximum is set to 200 to match the navigation limits; it can be tuned without a spec change.
