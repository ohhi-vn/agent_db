# Tasks

## 1. Instrumentation and benchmark foundations

- [x] 1.1 Declare `:telemetry` and `:opentelemetry_api` as direct runtime dependencies, and add Benchee plus the OpenTelemetry SDK as development/test-only dependencies; verify `mix deps.get` and `mix compile` succeed without requiring a runtime exporter.
- [x] 1.2 Add deterministic Benchee scenarios using isolated SQLite data and inference fakes for reads, tree projection, keyword/hybrid search, writes, and queue throughput; run them once and save baseline latency, throughput, and memory results with the scenario inputs.

## 2. Durable write and job scheduling outcomes

- [x] 2.1 Extend the `Core.Storage.put_document/3` contract so required background-job kinds are persisted atomically with the document; implement the transaction in the SQLite adapter and verify `mix test test/agent_db/adapters/sqlite_contract_test.exs` passes.
- [x] 2.2 Update `Documents.write/3` to pass the generated job set through the storage contract, propagate storage/enqueue errors, and invalidate cache only after commit; verify tests cover failed enqueue rollback for new and existing documents, unchanged queue/cache state, and successful async/sync writes.
- [x] 2.3 Update test storage providers and the storage contract suite for the extended option semantics; verify `mix test test/agent_db/core/contracts_test.exs test/agent_db/runtime_test.exs` passes.

## 3. Bounded runtime work and concurrency configuration

- [x] 3.1 Build embedding and summarization worker specifications from the validated `job_workers` setting with unique worker IDs; verify tests assert the configured count for both job families and startup rejects a non-positive count.
- [ ] 3.2 Convert hybrid-search timeout and task-exit outcomes into classified errors without exiting the caller, while retaining parallel legs and existing fusion behavior; verify tests cover successful fusion, a failed leg, timeout, and a subsequent usable WebSocket operation.

## 4. Correlated runtime observability

- [x] 4.1 Add the stateless observability helper and emit low-cardinality duration/outcome telemetry for public operations, model loading/inference, and job queue/execution transitions; verify telemetry tests assert event shape, outcome, queue-wait versus execution timing, and absence of URI/content/prompt/user dimensions.
- [x] 4.2 Add operation spans and W3C trace-context extraction for HTTP headers and per-event WebSocket metadata; verify valid, absent, and malformed contexts preserve existing authorization, error, response, and connection contracts.
- [x] 4.3 Persist optional trace propagation fields with new durable jobs, create independently finishable worker spans linked to enqueue traces, and start a new trace for old jobs without context; verify trace correlation across restart and legacy job-payload tests.
- [x] 4.4 Replace touched interpolated operational logs with structured fields and redact configured model URLs and sensitive error details; verify log-capture tests prove content, prompts, credentials, and secret URL parameters are absent.

## 5. Regression, performance comparison, and documentation

- [x] 5.1 Run `mix test` and `mix format --check-formatted`; verify storage atomicity, cache consistency, subtree-removal fencing, deferred-job retry accounting, restart recovery, sync-write outcomes, and unchanged HTTP/WebSocket payloads remain covered.
- [x] 5.2 Re-run the benchmark scenarios with the same inputs, compare results to the saved baseline, and retain only optimizations supported by repeatable measurements; verify performance results and any remaining model-manager bottleneck are documented.
- [x] 5.3 Update README operations guidance for worker-count semantics, trace context, host-provided SDK/exporter setup, redaction, error outcomes, and benchmark use; verify `openspec validate "improve-runtime-quality" --strict` succeeds.
