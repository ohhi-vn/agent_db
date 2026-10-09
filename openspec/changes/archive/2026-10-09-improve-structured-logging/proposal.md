# Proposal

## Why

Operational logs are only partly structured. `AgentDb.Observability` offers a
structured, redacted `log/2`, but roughly thirty call sites still emit
interpolated `Logger.*` strings and `inspect/1` of failure terms (storage,
memory recall, the model backends, and the job worker's own error paths), and
even the structured logs rarely carry trace correlation. The result is that a
failure is hard to follow from the request that caused it to the durable job it
enqueued. The `runtime-observability` spec already requires structured, redacted,
trace-correlated logs; this change closes the gap between that contract and the
code.

## What Changes

- Route every operational log through the single structured entry point
  (`Observability.log/2`), replacing interpolated `Logger.*` strings and raw
  `inspect/1` failure terms in the storage adapter, memory recall, the model
  backends, and the job worker.
- Carry trace correlation in logs: the structured logger attaches the active
  operation's trace id (and span id where known) to each log, and worker logs
  carry the job id together with the trace id the job was enqueued under.
- Make worker state-transition logs consistent: deferred, failed, discarded, and
  completed jobs all carry component, kind, outcome, classified reason, job id,
  and trace id.
- Preserve the existing redaction and taxonomy rules: no URIs, content, prompts,
  users, credentials, or secret-bearing URLs in log fields; failure reasons stay
  classified and bounded.
- No new dependency, no new spans, and no change to operation results or error
  contracts.
- **BREAKING**: none. Log output changes; no public API or error shape does.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `runtime-observability`: the structured-logging requirement is broadened from
  failures-and-transitions to all operational logs, and gains trace and job
  correlation identifiers.

## Impact

- `lib/agent_db/observability.ex` — per-process correlation context and the
  structured log entry point.
- `lib/agent_db/workers/job_worker.ex`, `lib/agent_db/ml/model_download.ex` —
  consistent worker/model logging with job and trace correlation.
- `lib/agent_db/store/sqlite.ex`, `lib/agent_db/application/memories.ex`,
  `lib/agent_db/ml/model_manager/backend.ex`,
  `lib/agent_db/ml/model_manager/backend/exla.ex`,
  `lib/agent_db/ml/model_manager/backend/emlx.ex` — migrate raw logs.
- Tests under `test/agent_db/observability_test.exs` and the affected call
  sites; the README's observability description if it states log fields.
