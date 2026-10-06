# Design

## Context

See proposal.md Why. Current state (observed): single `Store.Writer` runs every write callback without isolation (`store/writer.ex`); `store/sqlite.ex` releases handles only on success; no `busy_timeout`; `Store.Reader` shares connections without checkout; `JobQueue.claim` has no DB-error clause and `reset_running_jobs` clears attempts; `Workers.JobWorker` has no rescue so malformed payloads kill the `GenServer` and leak `running` jobs; `grep`/memory/session lists and `Cache`/`Sink` paths do full scans then truncate in Elixir; `Observability.error_message/1` echoes binaries and DB-string kinds become metric labels; `load_vec_extension` returns `:ok` on total failure; `String.to_integer` raises at boot; shutdown drain waits on never-draining `pending`.

Constraints: SQLite is source of truth (WAL, FK); ETS is disposable; no new runtime deps; public `{:ok}/{:error}` and transport envelopes keep their shapes; bench deltas only, no absolute latency in CI.

## Goals / Non-Goals

**Goals:**
- One bad write, claim, or job never kills the writer, worker, caller, or connection.
- Hot reads stay bounded at the storage layer with deterministic ordering.
- One bounded redacted taxonomy flows identically through telemetry, logs, and all transports.

**Non-Goals:**
- No FTS/trigram index or query-planner rewrite; `lower(..) LIKE` scans stay, only row/blob volume is bounded.
- No new pool library, ML runtime change, or ModelManager concurrency change.
- No new API versions or endpoint shapes.

## Decisions

- **Writer isolation in the writer, not supervision:** wrap `fun.(conn)` in `try/rescue/catch` and release the handle in `after`; return `{:error, classified}` to the caller. Alternative (let-it-crash + `one_for_one` restart) rejected: the writer is singleton state — a restart fails *all* in-flight writes, while isolation fails exactly one.
- **Busy handling where the invariant belongs (SQLite open + writer):** set `busy_timeout` PRAGMA at open and add one bounded retry with jitter in the writer for `SQLITE_BUSY`, then return retryable `:storage_busy`. Alternative (retry in every caller) rejected: duplicates the guard and drifts; single ownership keeps callers unchanged.
- **Reader checkout with lease, not shared list:** give each read connection an exclusive lease (checkout/checkin around `fun`) instead of round-robin over a shared list. Alternative (serialize all reads through writer) rejected: destroys the measured read throughput (`bench/baseline.md`); alternative (add pool dep) rejected: lifecycle cost outweighs a small lease in the owning module.
- **Queue stays honest:** `claim` gets an explicit `{:error, _}` clause returning classified error; `reset_running_jobs` flips `running→pending` without touching `attempts`; unknown `kind` is claimed once and marked failed with `{:unknown_job_kind, kind}` instead of staying pending; repeated dequeue storage errors back off exponentially. Preserving attempts is the root fix for poison-pill loops; reaping unknown kinds prevents silent growth.
- **Workers return outcomes, never raise:** rescue around dequeue/process/generate/store; malformed payloads and inference failures become `{:error, reason}` → retry/fail paths, and a crashed-while-`running` job is reclaimed on next claim/boot. `Jason.encode!/decode!` become `encode/decode` with `{:error, _}` mapping at the queue boundary.
- **Bound reads at the SQL/ETS layer:** push `LIMIT` (plus deterministic `ORDER BY uri, line`) into `grep`/memory/session queries and stop transferring full blobs; replace `ETS.tab2list` scans on removal/sink/cache with `select` + bounded iteration and targeted deletes. Add only two indexes: dequeue filter (`status, kind, scheduled_at`) and `json_extract(payload,'$.uri')` for `cancel/count_for_uri`. Alternative (full FTS + many indexes) rejected: write amplification and migration risk for unmeasured gain.
- **One taxonomy, enforced at the edge:** `Observability` maps any binary detail to a bounded code (never echoes), coerces unknown kinds to `:unknown`, and completes the caller-vs-server status table; every transport renders through that single classifier so REST/WebSocket/MCP/CLI agree. Vec-extension load failure returns `{:error, :vector_index_unavailable}` instead of silent `:ok`.
- **Config/shutdown fail safe:** extend `Runtime.validate!` to cover numeric/boolean env parsing (naming the variable) instead of raising mid-boot; shutdown drain waits only for `running` (workers already stopped, `pending` can never drain post-shutdown).

## Risks / Trade-offs

- [Risk] `busy_timeout` + retry masks real contention → Mitigation: bounded (single-digit seconds), jittered, emits `storage_busy` telemetry so ops still see it.
- [Risk] New indexes slow writes → Mitigation: two narrow indexes only; bench write scenario before/after, revert if write `ips` regresses beyond noise.
- [Risk] `LIMIT` pushdown changes which rows survive when ordering was implicit → Mitigation: fix `ORDER BY` explicitly in the same statement; existing order tests pin it.
- [Risk] Coercing unknown kinds/labels to `:unknown` hides a new failure mode → Mitigation: keep classified reason in the failed row/log detail (redacted), only the metric label is bounded.
- [Risk] Lease-based reader checkout can still starve under burst → Mitigation: bounded wait + `storage_busy` error, same contract as writes; no indefinite block.

## Migration Plan

1. Additive SQLite migration: PRAGMA `busy_timeout` at open; `CREATE INDEX IF NOT EXISTS` for the two indexes; `reset_running_jobs` update changes `SET status` only (no column change) — idempotent, safe to re-run.
2. Deploy: no data backfill; old rows (including unknown-kind) are handled by new claim path on first poll.
3. Rollback: revert code; new indexes are ignored by old code and can stay; no contract break because envelopes and `{:ok}/{:error}` shapes are unchanged.
4. Verify: `mix test`, `mix lint:quick`, bench write/grep/list scenarios for delta only.

## Open Questions

None — remaining unknowns (exact `busy_timeout` ms, backoff caps, index names) are implementation tuning that does not change specs, approach, or task breakdown.
