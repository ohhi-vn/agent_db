# Tasks

## 1. Console data foundation (facade → status → storage)

- [x] 1.1 Add `stats/0`, `document_count/1` (the per-prefix count the tree listing and code-index coverage read), `vector_index_stats/0`, and `queue_detail/1` callbacks to `AgentDb.Core.Storage` with documented contracts; verify `mix compile` and the storage contract suite (`test/agent_db/adapters/sqlite_contract_test.exs`) pass
- [x] 1.2 Implement the new callbacks in `AgentDb.Adapters.SQLite` (counts by kind, prefix counts via `Nodes.like_escape/1`, `MIN(scheduled_at)` over the status index, bounded failed rows, DB/WAL file sizes); verify contract tests plus new unit tests for totals, per-subtree counts, and queue detail
- [x] 1.3 Add a guarded nullable `last_error TEXT` column to `job_queue` in `Store.SQLite.ensure_schema/1` using `PRAGMA table_info`; verify boot against a database created without the column and that a second boot is a no-op
- [x] 1.4 Persist the classified failure reason: extend the port failure callback to `fail_job/2` and update `JobQueue.fail/2` and `JobWorker.fail/3` to store it; verify existing `test/agent_db/job_queue_test.exs` passes and a failed job reads back its reason
- [x] 1.5 Add `Status.storage/0`, `Status.cache/0`, `Status.queue_detail/0`, and `Status.index_coverage/0`, plus `AgentDb` facade functions and `Context` wrappers; verify `test/agent_db/boundaries_test.exs` passes and add unit tests for each composition
- [x] 1.6 Fix the document count and page handling: list the tree root with a valid scope and parse `page`/`per_page` with `Integer.parse/1` (bounded/clamped, never raising); verify a live/unit test shows a non-zero total for a non-empty store and an invalid `page` renders a bounded page

## 2. Observability sink and runtime snapshot

- [x] 2.1 Add a supervised `AgentDb.Observability.Sink` GenServer owning one ETS table; verify the application starts and the table is bounded
- [x] 2.2 Attach a telemetry handler in the sink for `operation.stop`, `job.stop`, and `model.stop`, recording bounded counters and a bounded recent-error ring; verify a test that emits events observes counts and at most the bound of error entries
- [x] 2.3 Add `Observability.recent_errors/0` and `Observability.operation_stats/0`; route the raw `Logger` failure sites (`job_worker.ex`, `store/sqlite.ex`, model backends, `model_manager.ex`) through `Observability.log/2`; verify no operational failure path uses raw `inspect(reason)` and tests cover the classified shape
- [x] 2.4 Add `uptime_ms` to `AgentDb.RuntimeContext` and expose `AgentDb.runtime_snapshot/0` plus a `Context` wrapper; verify the snapshot test asserts uptime, deterministic truncation, and redaction, and that no store process is messaged

## 3. Admin console enrichment

- [x] 3.1 Extract `AdminLive` render sections into function components in `AgentDbWeb.AdminComponents` (recent changes, import skills, search, models, queue, health, session lookup, documents); verify the existing `test/agent_db_web/live/admin_live_test.exs` assertions still pass
- [x] 3.2 Add storage-footprint, cache/memory, queue-detail, index-coverage, model-ops, and runtime/liveness sections wired only through `Context`; verify new live tests cover each section and that a model/index being unavailable renders an "unavailable" state rather than failing
- [x] 3.3 Render console failures from the shared taxonomy (`Observability.error_message/1`, `Context.skill_import_error/1`) instead of `inspect/1`; verify a live test asserts a classified reason and the absence of a raw term
- [x] 3.4 Show per-role model load state, last load duration, in-flight count, and the model-status queue depth from the durable queue; verify a live/status test asserts the values are present and the queue depth is not hardcoded zero

## 4. Targeted performance

- [x] 4.1 Route `Application.Documents.list/1` through `Cache.get_dir/2` / `Cache.put_dir/2`, caching both `{:ok, names}` and `:not_found`; verify list/tree correctness tests and the removal-invisible-to-cached-reads test pass
- [x] 4.2 Add `list`, `grep`, `find`, and a scaled keyword-corpus scenario to `bench/agent_db_bench.exs`; verify the harness runs and records a pre-change baseline
- [x] 4.3 Validate `:top_k` in `Application.Search` (default 10, max 200, classified error outside range) and push `LIMIT` into `Nodes.search/4` and the SQLite keyword query; verify keyword `top_k` tests and that a query matching more than `top_k` returns at most `top_k`
- [x] 4.4 Re-run the benchmark against the pre-change baseline; retain only deltas beyond the documented run-to-run spread, confirm memory is unchanged, and record the outcome in `bench/baseline.md`

## 5. Refactors (contracts unchanged)

- [x] 5.1 Create `AgentDb.Archive` with bounded tar/gzip detection, listing, member extraction, and non-regular-entry refusal parameterized by `max_bytes`; switch `Skills.Source` and `Application.DataTransfer` to it; verify both suites (`source_test.exs`, `data_transfer_test.exs`) pass unchanged
- [x] 5.2 Create `AgentDb.Store.Sessions` and `AgentDb.Store.Commits` and move the inline session/commit SQL, the single role mapper, and the single message reader into them; leave the adapter as thin delegations; verify the storage contract, session, and data-portability suites pass
- [x] 5.3 Create `AgentDb.ML.ModelDownload` for download/cache/`.part`-rename policy and move the EMLX→EXLA fallback into `Backend.load/2`; resolve the unused `model_info/0` callback; verify the `test/agent_db/ml/*` suites pass
- [x] 5.4 Single-source the session role map, `like_escape/1`, navigation query/limit/scope validation, and controller `transport_error/2`; verify unit tests for each consumer pass
- [x] 5.5 Add `Application.DataTransfer` (and the new store/archive modules as appropriate) to the core set in `test/agent_db/boundaries_test.exs`; verify the boundary test passes

## 6. Provider selection and code-health fixes

- [x] 6.1 Make `Runtime.inference/0` derive the adapter module from `Config.inference_provider/0` and raise on an unknown value; update `config/example.exs`, `docs/SETUP.md`, and the provider tests to a single key; verify `test/inference_providers_test.exs` passes with only the provider key set
- [x] 6.2 Report provider kind from the resolved adapter (not a parallel key) and expose provider health for remote providers; verify the provider-awareness and status tests pass and an unreachable remote provider is not reported ready
- [x] 6.3 Fix `AgentDb.CodeIndex.callback_names/2` to return the callbacks the module actually implements (not the discarded static list); verify `test/code_index_test.exs` asserts implemented callbacks
- [x] 6.4 Refuse non-regular (symlink/hardlink/non-file) archive members through the shared `Archive` used by data transfer; verify a new test asserts refusal and that a refused archive leaves the store untouched
- [x] 6.5 Remove dead code (`Context.list_sessions/1`, `Observability.events/0`, `AgentDb.memory_types/0`, `AgentDb.parse_uri/1`, unused `data_transfer_limits/0`, `JobQueue.last_insert_rowid/1`); verify `mix compile --warnings-as-errors` passes and no callers remain
- [x] 6.6 Fix `config/example.exs` so unset variables fall back to defaults instead of raising/always-true, and prune the unused `mix.lock` entry; verify the file evaluates with no env set and `mix deps.get` succeeds

## 7. Verification

- [x] 7.1 Run the full suite (`mix test`) and confirm all tests pass, including new tests for each added requirement
- [x] 7.2 Run `mix compile --warnings-as-errors` and `mix format --check-formatted` and confirm both pass
- [x] 7.3 Update `README.md` and `docs/` for the enriched console, the single provider key, and the bounded keyword `top_k`; verify each documented behavior matches the implementation
- [x] 7.4 Confirm the benchmark baseline is current and that every retained performance change has a recorded, repeatable delta
