# Troubleshooting

Symptom-first diagnostics. Find the symptom, run the diagnostic command,
compare against the expected healthy output, and apply the resolution. For
alerting and dashboards see [MONITORING.md](MONITORING.md); for the full API
surface see [API-REFERENCE.md](API-REFERENCE.md).

## Symptom Index

| Symptom | Go to |
|---------|-------|
| Daemon won't start | [1. Daemon won't start](#1-daemon-wont-start) |
| Model fails to load | [2. Model fails to load](#2-model-fails-to-load) |
| Search returns `model_loading` | [3. Search returns model_loading](#3-search-returns-model_loading) |
| Queue grows without draining | [4. Queue grows without draining](#4-queue-grows-without-draining) |
| High inference latency | [5. High inference latency](#5-high-inference-latency) |
| Authentication rejected | [6. Authentication rejected](#6-authentication-rejected) |
| WSL2 daemon unreachable from Windows | [7. WSL2 daemon unreachable from windows](#7-wsl2-daemon-unreachable-from-windows) |
| Admin console shows errors | [8. Admin console shows errors](#8-admin-console-shows-errors) |
| Export/import fails | [9. Export/import fails](#9-export/import-fails) |

## 1. Daemon won't start

**Diagnose:**

```bash
mix agent_db.doctor --json
```

Healthy:

```json
{"db":true,"status":"ok","provider":"local","queue":{"done":150,"failed":0},"pubsub":true}
```

`db` false (the task exits non-zero with `Database unreachable`) — the store
directory is missing or not writable. **Resolve:** point `AGENT_DB_DATA_DIR`
at a writable directory and re-run. `status` `degraded` or a `models`-related
warning does not stop the daemon — it degrades to no-model behavior, so treat
those separately (symptoms 2 and 3).

## 2. Model fails to load

Log signature: `component: "ModelManager"`, `reason: "download_failed"` or
`reason: "model_load_failed"`.

**Diagnose:**

```elixir
AgentDb.model_status()
# healthy: %{embedding: %{state: :ready, ...}, llm: %{state: :ready, ...}}
# unhealthy: %{embedding: %{state: :loading, ...}} (stuck) or %{state: :failed}
```

**Resolve, in order:**

1. **Truncated cache** — the most common cause: an interrupted download left
   a partial file. Delete the truncated cache file for the model and let it
   re-download (SETUP.md documents the model directory layout and
   pre-placement).
2. **Backend mismatch on Apple Silicon** — the EXLA backend must match the
   chip. Re-check the backend selection from SETUP.md.
3. **Disk space** — a full volume fails mid-download; free space and retry.
4. **Remote provider unreachable** — `model_status/0` reports the provider's
   health state; `:unreachable` means the endpoint did not answer, check the
   base URL and network. `:unauthorized` means the token was refused.

## 3. Search returns `model_loading`

The embedding model is still loading; vector and hybrid search wait for it
(`:keyword` mode works without a model).

**Diagnose:** `AgentDb.model_status()` — any role in `:loading` explains the
error. Logs show `reason: "model_loading"`.

**Resolve:** wait for the load (check `last_load_ms` after it succeeds). If a
role stays `:loading` for minutes, treat it as symptom 2. Keyword search and
`find`/`grep` stay available while a model loads — no action needed if the
caller can retry.

## 4. Queue grows without draining

**Diagnose:**

```elixir
AgentDb.queue_stats()
# healthy: counts per status present, e.g. %{pending: 0, running: 0, done: 150, failed: 0}
# (a status with no rows is absent from the map; a queue that cannot be read reports %{})

AgentDb.queue_detail(20)
# watch oldest_pending_ms (nil when nothing is pending) and the failed list
# with classified last_error reasons
```

```bash
mix agent_db.doctor   # reports db, status, provider, queue, and pubsub
```

**Resolve, in order:**

1. **Model loading** — embedding/summarization jobs cannot finish without a
   model; resolve symptom 2 first.
2. **Throughput too low** — raise the worker count (`job_workers` in the
   application config) and restart.
3. **Failed jobs** — read the classified `last_error` per failed job in
   `queue_detail/1` (e.g. `inference_timeout` — check symptom 5) and clear or
   retry as appropriate.

## 5. High inference latency

**Diagnose:** `model_status/0` reports `last_latency_ms` per role;
`queue_detail/1` reports pending age; telemetry carries
`[:agent_db, :model, :stop]` durations by `role`.

**Resolve, in order:**

1. A role in `:loading` blocks inference — resolve symptom 2.
2. A long queue (symptom 4) delays every job downstream.
3. A remote provider adds network round-trips — `model_status/0` shows the
   provider's health; `inference_timeout` in logs means the provider exceeded
   the request deadline. Switch to the local provider or raise the timeout.
4. Sustained load: check `queue_stats` running depth; if workers are all busy,
   raise `job_workers`.

## 6. Authentication rejected

The daemon returns 401 when auth is on and the token is missing or wrong.
Logs carry `reason: "unauthorized"`.

**Diagnose:** confirm whether auth is enabled and which token you sent:

```bash
# from inside the daemon host: the listener and auth settings
mix agent_db.doctor
```

**Resolve:** with `AGENT_DB_HTTP_AUTH=true`, the client must send
`Authorization: Bearer <token>` with a token from
`AGENT_DB_HTTP_AUTH_TOKENS`. The default (auth off) binds loopback only, so
a non-loopback client gets refused regardless of token.

## 7. WSL2 daemon unreachable from Windows

Run the daemon and the installer **inside WSL2**, and point Windows editors
at `http://localhost:6060/mcp`.

**Diagnose:**

```bash
# from PowerShell
wsl bash tools/install.sh --check
wsl bash -c "curl localhost:6060/api/v1/health"
```

**Resolve, in order:**

1. **Installer refuses to run natively** — `tools/install.ps1` refuses native
   execution on purpose: native Windows has no supported EXLA path, so a
   native install would look done while inference cannot work. Run it inside
   WSL.
2. **Windows firewall** — allow the port (6060 by default) or reach the
   daemon through WSL's forwarded `localhost`.
3. **Daemon bound inside WSL only** — start the daemon inside WSL2 and verify
   from Windows with the curl check above.

## 8. Admin console shows errors

The console renders the same data as the health functions.

**Diagnose:**

```elixir
AgentDb.recent_errors(20)
# bounded list of recent operational errors with their classified codes
```

Match the `code` against the [API-REFERENCE error catalog](API-REFERENCE.md#5-error-code-catalog)
and jump to the matching symptom above. Console panels that stay empty with
the daemon up are usually the listener question (symptom 6/7).

## 9. Export/import fails

**Diagnose:** the failure reason from `AgentDb.export_data/2` /
`AgentDb.import_data/2`, classified with
`AgentDb.export_data_error_message/1`; limits are `AgentDb.data_transfer_limits/0`.

**Resolve, in order:**

1. **Over a limit** (entry count or size) — the bounds are in
   `data_transfer_limits/0`; split the transfer or narrow the `scope:`.
2. **Permission or disk** — the destination path must be writable with free
   space.
3. **Corrupt archive** — a partially written export; re-export.

## Reading the Logs

All operational failures log structured fields (never content, prompts, URIs,
or credentials):

| Field | Meaning |
|-------|---------|
| `component` | Subsystem that logged (`"ModelManager"`, `"JobWorker"`, `"Storage"`) |
| `operation` | What was attempted (`:embed`, `:summarize_abstract`, `:write`, `:search`) |
| `kind` | Subtype of the operation or job |
| `role` | Model role (`:embedding`, `:llm`) |
| `outcome` | `:ok` or `:error` |
| `reason` | The classified error code — the same tag as the transport's error `code` |
| `trace_id` / `span_id` | W3C trace correlation |
| `job_id` | Background job identity |

Pattern: an `outcome: :error` line's `reason` names the failure mode and maps
1:1 to the error catalog, so `reason: "model_load_failed"` is symptom 2 and
`reason: "inference_timeout"` is symptom 5.
