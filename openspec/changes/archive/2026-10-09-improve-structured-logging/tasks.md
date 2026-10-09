# Tasks

## 1. Structured logging entry point with correlation

- [x] 1.1 Add a per-process correlation context to `AgentDb.Observability` (`with_correlation/2`, read by `log/2`), restoring the previous value in `after`; verify a unit test that a log emitted inside the context carries the correlation and that the context is empty afterward
- [x] 1.2 Make `log/2` merge the correlation context into its emitted fields and keep classifying `reason`; verify a test that the emitted fields include `trace_id`/`job_id` when set
- [x] 1.3 Attach the active span id in `timed/3`, `stage/4`, and `with_span/3` when OpenTelemetry is live, without inventing a trace id; verify existing search/write tests still pass
- [x] 1.4 Configure the default Logger formatter in `config/config.exs` to render the bounded structured fields (`component`, `operation`, `kind`, `role`, `outcome`, `reason`, `trace_id`, `span_id`, `job_id`); verify a captured log shows the component, outcome, and trace id rather than only the `agent_db` message

## 2. Operation and durable-job correlation

- [x] 2.1 Set correlation from the `:trace_context` option at the entry of `AgentDb.Application.Documents.write` and `AgentDb.Application.Search.search`; verify a test that a write/search with a trace context emits logs and a job `_trace` carrying that trace id
- [x] 2.2 Set correlation in `AgentDb.Workers.JobWorker.process/3` from the job's id and `_trace` for the whole job and restore it after; verify logs for completed, deferred, failed, and discarded jobs each carry the job id and (when present) the trace id

## 3. Migrate raw log call sites

- [x] 3.1 Replace the raw `Logger.*` calls in `lib/agent_db/store/sqlite.ex` with structured `Observability.log/2` fields (component, operation, outcome, classified reason); verify the storage tests pass and the lines no longer interpolate or `inspect`
- [x] 3.2 Replace the raw `Logger.*` calls in `lib/agent_db/application/memories.ex` with structured fields, dropping the document URI from the held-candidate logs; verify the memory tests pass and no log field carries a URI
- [x] 3.3 Replace the raw `Logger.*` calls in `lib/agent_db/ml/model_manager/backend.ex`, `backend/exla.ex`, and `backend/emlx.ex` with structured fields and classified reasons; verify the model tests pass
- [x] 3.4 Replace the raw `Logger.*` calls in `lib/agent_db/workers/job_worker.ex` (dequeue error, crash, catch) with structured fields; verify the worker tests pass
- [x] 3.5 Confirm `lib/agent_db/ml/model_download.ex`'s existing structured logs carry correlation where available and its redacted URLs are unchanged; verify the download tests pass

## 4. Verification

- [x] 4.1 Extend `test/agent_db/observability_test.exs` to assert correlation is attached inside a context, absent afterward, and that no raw failure term is emitted as a field
- [x] 4.2 Add a guard test that no module under `lib/` other than `AgentDb.Observability` calls `Logger` directly, so operational logs keep one entry point; verify it passes and fails if a raw call is reintroduced
- [x] 4.3 Run `mix test` and `mix lint:quick`; verify both pass with the change in place

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
