# Tasks

## 1. Writer and reader hardening

- [x] 1.1 Isolate writer callbacks with try/rescue/catch plus after-release and verify a bad-payload write returns `{:error, _}` and a following valid write succeeds in `mix test test/agent_db/store_writer_test.exs` (or nearest store test)
- [x] 1.2 Release SQLite handles on bind/step/callback error paths and verify no handle leak is reported in writer/sqlite unit tests
- [x] 1.3 Set `busy_timeout` PRAGMA at open plus bounded jittered retry returning retryable `:storage_busy` and verify contended-write test passes without crash
- [x] 1.4 Add exclusive-lease checkout/checkin to reader connections and verify concurrent read test passes with no shared-connection use

## 2. Durable queue and workers

- [x] 2.1 Replace `Jason.encode!/decode!` with `{:ok}/{:error}` mapping at queue boundary and verify malformed-payload test returns classified error instead of raising
- [x] 2.2 Add DB-error clause to claim plus exponential backoff on repeated dequeue failure and verify claim-error test keeps writer alive and worker retries
- [x] 2.3 Preserve `attempts` in `reset_running_jobs`, keep deferral off-budget, and mark unknown kinds failed and verify poison-pill-across-restart and unknown-kind tests pass
- [x] 2.4 Rescue worker dequeue/process/generate/store into job outcomes with `running` reclamation and verify malformed-job test leaves worker alive and job failed/retried, not leaked

## 3. Bounded reads and indexes

- [x] 3.1 Push `LIMIT` with deterministic `ORDER BY` into grep/memory/session queries and verify limit tests transfer only bounded rows (no full-blob materialization)
- [x] 3.2 Replace `ETS.tab2list` scans on removal/sink/cache paths with bounded `select` plus targeted deletes and verify removal and recent-errors tests pass with bounded reads
- [x] 3.3 Add `CREATE INDEX IF NOT EXISTS` for dequeue filter and `json_extract(payload,'$.uri')` cancel/count and verify `mix test` dequeue/cancel tests use the indexes with no write-path regression

## 4. Errors, transports, config, shutdown

- [x] 4.1 Bound `Observability` taxonomy (map binaries, coerce unknown kinds to `:unknown`, redact URIs/content/credentials) and verify telemetry/log tests show bounded codes with no sensitive values
- [x] 4.2 Complete caller-vs-server status mapping and JSON-safe rendering on REST/WebSocket/MCP/CLI and verify same invalid request returns same `code` on every transport with no 500 and no terminated connection
- [x] 4.3 Surface vec-extension load failure as `{:error, :vector_index_unavailable}` and verify unavailable-vector test reports classified error, not silent `:ok`
- [x] 4.4 Validate numeric/boolean env (e.g. `AGENT_DB_JOB_WORKERS`) naming the setting and drain only `running` on shutdown and verify invalid-config boot test and shutdown test pass

## 5. Gate verification

- [x] 5.1 Run full suite plus gates and bench deltas and verify `mix test`, `mix lint:quick`, and `mix run bench/agent_db_bench.exs` write/grep/list scenarios show no regression vs `bench/baseline.md` (deltas only, no absolute latency assert)
