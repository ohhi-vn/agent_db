# Proposal

## Why

AgentDb is a single-writer SQLite store with async embedding/summarization jobs and multiple transports. Code inspection shows single-process crash paths (writer `handle_call`, job claim, worker `GenServer`), unbounded reads (`grep`, memory/session lists, ETS scans), and inconsistent error classification that can crash the writer, leak jobs, or return 500/terminate connections for caller-fixable input.

## What Changes

- Harden single-writer path: isolate callback crashes to caller errors, release SQLite handles on all paths, add `busy_timeout` + bounded write retry; fix reader checkout to avoid shared-connection concurrency.
- Harden durable queue: claim handles DB errors without crashing writer; `reset_running_jobs` preserves attempt history so poison pills stay bounded; unknown-kind rows cannot accumulate silently; dequeue backoff on repeated storage failure.
- Harden workers: malformed payloads and inference failures become job outcomes (`{:error, reason}` → retry/fail), never `GenServer` crashes; leaked `running` jobs are reclaimed.
- Bound hot reads: push `LIMIT` into `grep`/list/session SQL, avoid full-table blob transfer and `ETS.tab2list` scans on removal, sink, and cache paths; add missing indexes for dequeue filter and `cancel/count_for_uri`.
- Make errors consistent and safe: replace `Jason.encode!/decode!` raises with `{:error, _}` returns; bound `Observability` taxonomy (no verbatim binaries, no DB-string kinds as metric labels); complete caller-vs-server status mapping; JSON-safe transport envelopes that never terminate caller/connection.
- Fail safe on config/shutdown: invalid env (e.g. non-integer `AGENT_DB_JOB_WORKERS`) is a startup validation error, not a boot raise; shutdown drain only waits for `running`, not never-draining `pending`; `load_vec_extension` failure surfaces explicitly instead of silent `:ok`.

## Capabilities

### New Capabilities

None — this change hardens existing behavior, no new capability.

### Modified Capabilities

- `context-store`: durable write + job-queue resilience (crash isolation, busy retry, attempt preservation, bounded retries/backoff) and bounded reads (SQL `LIMIT`, indexed dequeue/cancel, no unbounded scans).
- `runtime-observability`: bounded, redacted error taxonomy — same code in telemetry, logs, and transport; no content/URI/credential leak; queue-wait vs execution stays distinguishable.
- `http-api`: consistent transport errors — caller errors are 4xx with `code`, server failures are 5xx/error-envelope with classified reason, never a raw term and never connection termination.

## Impact

- Affected code: `lib/agent_db/store/{writer,reader,sqlite,nodes,memories,sessions}.ex`, `lib/agent_db/job_queue.ex`, `lib/agent_db/workers/*.ex`, `lib/agent_db/cache.ex`, `lib/agent_db/observability*.ex`, `lib/agent_db/application.ex`, `lib/agent_db/config.ex`, transport error renderers (`AgentDbWeb` channel/controller/MCP/CLI).
- APIs: no new endpoints; existing `{:ok}/{:error}` and WebSocket/MCP/CLI envelopes unchanged in shape, stricter in `code`/status consistency.
- Dependencies/systems: no new deps; SQLite PRAGMAs/indexes only; bench scenarios reused for before/after deltas, no absolute latency asserted in CI.
