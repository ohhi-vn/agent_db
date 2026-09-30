# Design

## Context

See `proposal.md` for motivation. The completed architecture separates `AgentDb` workflows from SQLite, inference, and Phoenix through core-owned ports; `AgentDb.BoundariesTest` and adapter contract tests protect those seams. SQLite is the source of truth, writes and subtree removal coordinate URI-keyed state, ETS is disposable, and worker results are fenced against removed nodes. Preserve these guarantees and the public `AgentDb` facade.

The current `Documents.write/3` persists the document and separately calls `enqueue_job/2`, discarding the enqueue results. `AgentDb.Config.job_workers/0` is configured but `Application.worker_specs/0` starts one worker per job family. Hybrid search awaits two linked tasks with a timeout that may exit the caller. `ModelManager` runs inference inside one GenServer, so more workers do not necessarily increase inference throughput. Existing logs use interpolated strings; no application telemetry or OpenTelemetry instrumentation or performance benchmark suite is present. `Plug.RequestId` is already installed, and the job queue payload is persisted as JSON, allowing optional trace metadata without a table migration.

## Goals / Non-Goals

**Goals:**

- Add measurements, structured error/state logs, and distributed trace propagation at existing application and infrastructure boundaries.
- Keep telemetry useful without an exporter and make exported traces available when the host configures an OpenTelemetry SDK/exporter.
- Make document persistence and required job scheduling a single durable outcome, and make bounded operation failures return through existing error contracts.
- Honor the configured worker count, but tune throughput only from repeatable measurements and within safe model/memory limits.
- Retain the current module ownership, public facade, job persistence format, and consistency rules.

**Non-Goals:**

- Replace the existing architecture, storage engine, background queue, or model runtime; redesign model serving before profiling it.
- Select or ship a vendor-specific trace exporter, metrics backend, or production log formatter.
- Put document data, prompts, URI/user identifiers, or secrets into metric dimensions or trace attributes.
- Set arbitrary latency thresholds before collecting representative baselines or require model downloads for CI.

## Decisions

### Instrument existing boundaries instead of adding a diagnostics service

Use a small stateless instrumentation module to define AgentDb's low-cardinality `:telemetry` event names, duration/outcome measurements, span helpers, and trace-related Logger metadata. Call it from the existing application workflows, transport edge, storage/inference boundaries, model loading, and worker lifecycle. Do not create a new GenServer, metrics endpoint, or behavior for the single instrumentation implementation. Declare `:telemetry` directly because AgentDb will call it directly.

Use `opentelemetry_api` for spans and W3C trace-context extraction/injection. The API is a no-op when the host has not configured an SDK; local `:telemetry` events and structured Logger entries remain available. The host owns SDK, sampler, exporter, and formatter configuration, avoiding a fixed network endpoint, exporter, or vendor dependency. Test builds may use the OpenTelemetry SDK to assert span relationships without including it in runtime dependencies.

Metrics use bounded dimensions such as operation, job kind, and outcome. Trace/log correlation may contain trace/span IDs and an internal job ID, but not the document URI, document content, model prompt, user ID, credential, or token. Redact configured model URLs before logging; error inspection must not bypass that redaction. Emit operation failures and meaningful worker/model state transitions as structured Logger fields without replacing the host application's Logger handlers or formatter.

### Carry trace context across process and durable-job boundaries

At HTTP boundaries extract W3C `traceparent`; at WebSocket boundaries accept it per event, since a long-lived socket is not one request span. Missing or invalid context starts a root trace and does not affect auth, authorization, or operation outcomes. Attach trace context and safe Logger metadata in each process that executes work rather than relying on process-local metadata to cross Tasks or GenServer messages.

Persist only the W3C propagation fields with the existing JSON job payload. A worker starts a distinct execution span linked to the enqueuing span, so work remains correlatable after the request span ends and after a restart. Jobs already stored without propagation fields start a new trace. This is an additive payload key; it requires no SQLite table migration and does not change the public API or job state model.

### Make write and job enqueue transactional at the storage owner

Pass the computed required job kinds through an internal option on the existing `Core.Storage.put_document/3` callback. The SQLite adapter will write the document and all required queue rows in one existing writer transaction. `Documents.write/3` invalidates cache only after that operation commits, then either returns the asynchronous acknowledgement or waits for those jobs in synchronous mode. A failure rolls back both the write and partial queue rows, returns a classified error, and leaves cached data untouched. This keeps SQL and transaction ownership inside the storage adapter and does not add a callback or change its arity. Custom storage adapters must implement the extended option semantics; update the storage contract tests to enforce them.

### Measure before optimizing; honor configured worker count

Add development-only Benchee scenarios with isolated temporary SQLite data and deterministic inference fakes for read/tree/search/write/queue workloads. Capture baseline latency, throughput, and memory before changing hot paths; do not assert absolute performance values in CI. Keep a separate warmed-model procedure for inference on hosts that have weights, with no model download in automated verification.

Use the existing `job_workers` setting as the worker count for each current job-family pool (embedding and summarization), and document the resulting total process count. This follows the current separate handlers and keeps each worker restricted to jobs it can execute. Validate a positive configured count. Do not infer that increasing the count improves throughput: first measure queue wait, job execution, model-manager utilization, and memory. Keep ModelManager's current serialization unless measurements and model-runtime safety justify changing it.

Replace hybrid search's unbounded caller-exit timeout path with bounded concurrent task collection that maps timeout or task failure to a classified `{:error, _}` result. Preserve both-leg fusion when both legs succeed and the current error behavior when a required leg fails; do not add a Task supervisor solely for this one operation.

### Keep operational error and wire contracts stable

For model-load, inference, worker, and hybrid-search failures, retain tagged error results and distinguish deferred `:model_loading` from actual failure. Ensure logging/instrumentation failures cannot replace an operation result. Keep HTTP and WebSocket success/error payloads unchanged; trace context is optional request/event metadata, not a new response field. Continue to use existing authorization and request validation at the transport boundary.

### Coordinate with active inference work

Apply spans around the stable inference port and its public outcomes, not internal Bumblebee serving details. Re-read and integrate the active `port-inference-to-bumblebee-serving` and `emlx-support` changes before touching ModelManager or its loader so instrumentation does not conflict with serving/backend changes.

## Risks / Trade-offs

- [A telemetry consumer or host exporter may add latency] → Keep in-process instrumentation low-cardinality, use the host's batching exporter, measure instrumentation overhead against the baseline, and never perform exporter I/O in an operation callback.
- [Trace metadata persisted in queued jobs could be mistaken for a content field or old payloads could lack it] → Store it in a namespaced optional metadata key, ignore absence, and test pre-existing payload compatibility and restart recovery.
- [The existing adapter contract is relied on by custom storage providers] → Preserve callback arity, document the new `put_document/3` option, and provide contract tests that custom providers can run.
- [More workers can increase model contention or memory without improving throughput] → Honor the explicit setting, measure both job families and model-manager saturation, and keep current inference serialization until evidence supports a safe change.
- [Failure details and configurable download URLs may contain secrets or user data] → Use classified reasons, redact URLs, exclude content and prompts, and assert redaction in log-capture tests.
- [The repository has concurrent model-serving changes] → Instrument the inference behavior boundary and integrate after reviewing those active changes; do not duplicate or replace their loader/serving design.

## Migration Plan

1. Add the direct telemetry/OpenTelemetry API dependencies and development/test-only benchmark and SDK tooling; preserve host ownership of runtime exporters.
2. Add transactional document-plus-job persistence through the existing storage callback, propagate failures, and extend provider contract tests before adding instrumentation to that path.
3. Make configured worker counts effective, handle hybrid task exits/timeouts as result errors, and verify the existing removal, restart, cache, deferred-job, and synchronous-write invariants.
4. Add bounded measurements, structured/redacted logs, and operation/job spans; propagate optional HTTP/WebSocket trace context and durable job context.
5. Capture benchmark baselines and compare affected paths after the changes; optimize only measured bottlenecks, then update documentation.

No database schema migration is expected: job trace metadata is an optional field in JSON payloads. Rollback is a code rollback with existing job rows still readable; newer workers must tolerate jobs without trace metadata. If the storage callback's new option semantics cannot be deployed with all configured adapters, do not enable the changed write path until those adapters pass the storage contract suite.
