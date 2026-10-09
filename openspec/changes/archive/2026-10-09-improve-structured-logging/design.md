# Design

## Context

See `proposal.md` for motivation. What shapes the approach:

- `AgentDb.Observability.log/2` already accepts a bounded field set
  (`component`, `operation`, `kind`, `role`, `outcome`, `reason`, `trace_id`,
  `job_id`), classifies `reason`, and emits `Logger.log(level, "agent_db", fields)`.
  It is the entry point to build on, not to replace.
- About thirty call sites still use interpolated `Logger.*` with `inspect/1`:
  `store/sqlite.ex` (9), `application/memories.ex` (6),
  `ml/model_manager/backend.ex` (4), `backend/exla.ex` (5), `backend/emlx.ex`
  (1), and `workers/job_worker.ex`'s own error paths (3). Some carry a URI
  (`memories.ex:186,190`).
- Trace context already exists end to end but is not attached to logs: the web
  layer parses an incoming `traceparent` (`Observability.from_conn/extract_context`),
  passes it as `:trace_context` into `search`/`write`, and `documents.ex` stores
  it in a job payload as `_trace`. `job_worker.ex` reads `_trace` for two of its
  logs but not the defer/fail paths, and no non-worker log carries a trace id.
- OpenTelemetry is a no-op without a host SDK (`opentelemetry` is dev/test only,
  `runtime: false`), so a trace id is only ever an incoming/derived value, never
  something the store can assume.

## Goals / Non-Goals

**Goals:**

- Every operational log is structured and goes through one entry point.
- Logs carry the trace id (and span id when known) of the operation or job they
  belong to, plus the job id for durable work.
- Worker state-transition logs are consistent across deferred, failed,
  discarded, and completed.
- No sensitive value (URI, content, prompt, user, credential, secret URL) can
  reach a log field.

**Non-Goals:**

- No new spans, no OTel SDK or exporter, no change to how `:trace_context`
  parents spans (that is the "Distributed traces" requirement, not this change).
- No new dependency.
- No change to operation results, error shapes, or telemetry events/counters.

## Decisions

### Keep `Observability.log/2` and attach correlation automatically

Extend `log/2` so it merges a per-process correlation context into the fields it
emits, rather than requiring each call site to pass `trace_id`. Call sites keep
passing only what they know (component, operation/kind, outcome, reason); the
correlation id travels with the process. Alternative: add `trace_id` to every
call site (easy to forget, and the request process would have to thread it
through every function). Alternative: read the OpenTelemetry span context
directly (nil without a host SDK, so most logs would lose correlation).

### Carry correlation in a per-process context, not Logger metadata

`Observability` keeps `:agent_db_correlation` in the process dictionary, set by
`with_correlation/2` and read by `log/2`. Process-scoped and explicit, and it
works with the project's existing formatter without depending on `Logger.metadata`
being rendered. It must be restored with `try/after`: the job workers and
LiveView/channel processes are long-lived, so a correlation left behind would
attach to an unrelated later operation. Alternative: `Logger.metadata/1` is
idiomatic, but it duplicates the correlation into a second channel and its
rendering depends on formatter configuration.

### Set correlation at operation and job entry, from what is available

- The operation wrappers (`timed/3`, `stage/4`) and `with_span/3` read the
  current correlation and attach the active span id when OTel is live; they do
  not invent a trace id when none is present (the spec says *available*
  identifiers).
- `Application.Documents.write` and `Application.Search.search` set correlation
  from their `:trace_context` option before doing work, so their logs and the
  `_trace` they enqueue share the incoming trace.
- `JobWorker.process/3` sets correlation from the job (`job_id` plus
  `_trace.trace_id`/`_trace.span_id`) for the whole job and restores it after, so
  every worker log — including the defer/fail/discard paths — is correlated.

### Migrate raw call sites, classify, and drop URIs from log fields

Each raw `Logger.*` becomes `Observability.log/2` with the closest structured
fields; the free-form `inspect(reason)` becomes a classified `reason`. The
structured entry point only accepts the bounded field set, so the URI in the
memory-recall debug logs cannot be emitted through it; those become a bounded
`component: :memory, operation: :recall, outcome: :held` (with a `kind` for
confidence/duplicate) and no URI. Truly internal, non-operational lines (if any)
are removed rather than kept as unstructured noise.

### Render the structured fields in the default formatter

The default formatter is configured with `metadata: []`, so a log renders as
`[error] agent_db` and the fields it carries are invisible in the console. The
structured logger is only useful for tracing if an operator can read the fields,
so `config/config.exs` sets `config :logger, :default_formatter, metadata:` to
the bounded structured keys (`component`, `operation`, `kind`, `role`, `outcome`,
`reason`, `trace_id`, `span_id`, `job_id`). A log then reads
`agent_db [component: :worker, outcome: :failed, trace_id: ...]`. This is the one
piece of the change that is configuration rather than call-site migration, and it
is what makes the rest visible.

### Leave the test log level as-is

`config/test.exs` sets `Logger` level `:warning`, so migrated `:info` logs do
not appear in tests. Tests assert on `:warning`/`:error` logs (as the existing
`capture_log` test does), now including the rendered metadata; the migration does
not raise levels to be testable.

## Risks / Trade-offs

- [A long-lived process keeps a stale correlation and mislabels later logs] →
  Every setter restores the previous value in `after`; a test asserts the context
  is empty after an operation completes.
- [Changing log call sites drops a detail someone relies on] → The bounded
  fields keep component, operation/kind, outcome, and classified reason; the
  detail was already required to be classified and detail-free, so nothing a
  consumer may depend on is lost.
- [Migrating `:info` notices to structured fields hides them under the test log
  level] → Intended; tests assert on warnings/errors and on fields, and the
  development/production levels are unchanged.
- [Attaching a trace id only when one is available means some logs have none] →
  Matches the spec's "available trace correlation identifiers"; generating ids
  where there is no trace is left to the separate spans work.

## Migration Plan

Reverting is source-only: restore the raw `Logger.*` calls and the previous
`log/2`. No data migration, no configuration, no API change.

## Open Questions

- Whether to mint a local correlation id for operations that have no incoming
  trace (so even untraced operations correlate in logs) is deferred; it belongs
  with the trace-creation work, not this change.
