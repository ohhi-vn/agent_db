# Monitoring

Production monitoring and observability guide for AgentDb. Covers the `/admin` console, telemetry events, structured logs, health checks, error taxonomy, and alerting recommendations.

## /admin Console (Primary Operational Interface)

The `/admin` console is a real-time LiveView dashboard at `http://localhost:6060/admin` (or your configured host/port). It subscribes to context changes via PubSub and updates without manual reload.

### Console Sections

| Section | What It Shows | Source |
|---------|---------------|--------|
| **Storage** | Database and WAL byte sizes; document/directory counts overall and per top-level subtree | `AgentDb.storage_stats/0` |
| **Cache** | Entry counts and memory per ETS cache table | `AgentDb.cache_stats/0` |
| **Runtime** | Node uptime, supervisor/process counts, BEAM memory | `AgentDb.runtime_snapshot/0` |
| **Models** | Per role: load state (`:loading`/`:ready`/`:failed`/`:idle`), last load duration, last inference latency, in-flight count, model identity, provider, remote provider health | `AgentDb.model_status/0` |
| **Queue** | Per-status counts (`pending`/`running`/`done`/`failed`), oldest pending age, failed jobs with kind, URI, attempts, classified reason | `AgentDb.queue_stats/0`, `AgentDb.queue_detail/1` |
| **Index** | Vector index row count vs indexed documents; code index documents; Hex-doc packages locked/indexed | `AgentDb.index_coverage/0` |
| **Recent Errors** | Bounded newest-first list: operation + classified reason only | `AgentDb.recent_errors/1` |
| **Recent Changes** | Feed of URI, kind (`written`/`removed`/`replaced`/`committed`), monotonic version | PubSub subscription |

### Using the Console

**Quick health check**: Open `/admin` and verify:
- Storage: DB size > 0, document count matches expectation
- Models: All roles show `:ready` (not `:loading` or `:failed`)
- Queue: `pending` count is low, `failed` = 0, oldest pending age is recent
- Index: Vector index available with row count ≈ document count
- Recent Errors: Empty or only expected transient errors

**Diagnose queue backpressure**:
1. Check Queue section: high `pending` count + growing `oldest_pending_ms`
2. Click failed jobs to see classified reasons (e.g., `:model_load_failed`, `:inference_timeout`)
3. Check Models section: any role stuck in `:loading`?
4. Check Runtime: BEAM memory/process count normal?

**Distinguish cache growth from content growth**:
- Cache section shows per-table entry counts and bytes
- Storage section shows document counts per subtree
- If BEAM memory rises but Storage document counts are flat → cache growth
- If both rise proportionally → content growth

## Telemetry Events

AgentDb emits `:telemetry` events with **bounded dimensions only** — never URIs, content, prompts, users, or credentials as label values.

### Event Catalog

| Event | When Emitted | Measurements | Metadata (Dimensions) |
|-------|--------------|--------------|----------------------|
| `[:agent_db, :operation, :stop]` | Public operation completes (success or error) | `duration_ms` | `operation` (atom), `outcome` (`:ok`/`:error`), `kind` (optional), `role` (optional) |
| `[:agent_db, :job, :stop]` | Background job completes (claimed → done/failed) | `queue_wait_ms`, `execution_ms` | `kind` (`:embed`/`:summarize_abstract`/`:summarize_overview`), `outcome` (`:ok`/`:error`) |
| `[:agent_db, :model, :stop]` | Model load or inference completes | `duration_ms` | `role` (`:embedding`/`:llm`), `outcome` (`:ok`/`:error`) |

### Retrieval Pipeline Stages (Child Spans)

When OpenTelemetry is configured, each retrieval stage creates a child span:

| Stage | Span Name | Attributes |
|-------|-----------|------------|
| Intent analysis | `agent_db.intent` | `stage: :intent`, `mode`, `outcome` |
| Resource search | `agent_db.resource_search` | `stage: :resource_search`, `mode`, `outcome` |
| Memory search | `agent_db.memory_search` | `stage: :memory_search`, `mode`, `outcome` |
| Skill retrieval | `agent_db.skill_retrieval` | `stage: :skill_retrieval`, `mode`, `outcome` |
| Embedding | `agent_db.embedding` | `stage: :embedding`, `mode`, `outcome` |
| Reranking | `agent_db.rerank` | `stage: :rerank`, `mode`, `outcome` |
| Context assembly | `agent_db.assembly` | `stage: :assembly`, `mode`, `outcome` |
| LLM call | `agent_db.llm_call` | `stage: :llm_call`, `mode`, `outcome` |

**Bounded Dimensions Rule**: All events/spans carry only `stage`, `mode`, `outcome`, `duration`. Never URIs, content, prompts, users, credentials.

### Consuming Telemetry (Prometheus/Grafana Example)

```elixir
# In your application startup
:telemetry.attach_many("my-metrics", [
  [:agent_db, :operation, :stop],
  [:agent_db, :job, :stop],
  [:agent_db, :model, :stop]
], &MyMetrics.handle_event/4, %{})
```

```elixir
defmodule MyMetrics do
  def handle_event([:agent_db, :operation, :stop], %{duration_ms: duration}, %{operation: op, outcome: outcome}, _config) do
    Prometheus.Histogram.observe(:agent_db_operation_duration, duration, labels: [operation: op, outcome: outcome])
  end

  def handle_event([:agent_db, :job, :stop], %{queue_wait_ms: wait, execution_ms: exec}, %{kind: kind, outcome: outcome}, _config) do
    Prometheus.Histogram.observe(:agent_db_job_queue_wait, wait, labels: [kind: kind, outcome: outcome])
    Prometheus.Histogram.observe(:agent_db_job_execution, exec, labels: [kind: kind, outcome: outcome])
  end

  def handle_event([:agent_db, :model, :stop], %{duration_ms: duration}, %{role: role, outcome: outcome}, _config) do
    Prometheus.Histogram.observe(:agent_db_model_duration, duration, labels: [role: role, outcome: outcome])
  end
end
```

**Dashboard Recommendations**:
- Operation latency by `operation` + `outcome` (p50, p95, p99)
- Job queue wait vs execution by `kind` + `outcome`
- Model inference latency by `role` + `outcome`
- Error rate by `operation` + `outcome`

## Structured Logs

All operational failures and background-job state transitions are logged as structured events via `Logger` with the `agent_db` metadata key.

### Log Fields

| Field | Description | Example |
|-------|-------------|---------|
| `component` | Subsystem that logged | `"ModelManager"`, `"JobWorker"`, `"Storage"` |
| `operation` | Operation kind | `:embed`, `:summarize_abstract`, `:write`, `:search` |
| `kind` | Job/operation subtype | `:embed`, `:summarize_overview` |
| `role` | Model role | `:embedding`, `:llm` |
| `outcome` | `:ok` or `:error` | `:error` |
| `reason` | Classified error code (see Error Taxonomy) | `:model_load_failed`, `:download_failed` |
| `trace_id` | W3C traceparent trace_id (if available) | `"4bf92f3577b34da6a3ce929d0e0e4736"` |
| `job_id` | Background job ID (if applicable) | `12345` |

**Redaction Guarantees**: Logs never contain document content, model prompts, authentication tokens, credentials, or unredacted secret-bearing URLs. URLs with credentials are redacted via `Observability.redact_url/1`.

### Log Aggregation Example (JSON)

```json
{
  "timestamp": "2026-01-15T10:30:45.123Z",
  "level": "error",
  "logger": "agent_db",
  "message": "agent_db",
  "metadata": {
    "component": "ModelManager",
    "operation": "embed",
    "kind": "embedding",
    "outcome": "error",
    "reason": "model_load_failed",
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"
  }
}
```

## Health Checks

### Programmatic Health Checks

```elixir
# Full health check (for orchestration liveness/readiness probes)
AgentDb.health_check()
# => %{status: "healthy" | "degraded", checks: %{db: true, models: true}}

# Model status detail (includes loading state)
AgentDb.model_status()
# => %{
#      embedding: %{state: :ready, last_load_ms: 1200, last_latency_ms: 45, ...},
#      llm: %{state: :loading, ...}
#    }

# Queue depth and backlog
AgentDb.queue_stats()
# => %{pending: 5, running: 2, done: 150, failed: 0}

# Detailed queue (oldest pending age + failed jobs)
AgentDb.queue_detail(20)
# => %{oldest_pending_ms: 45000, failed: [%{kind: :embed, uri: "...", attempts: 3, last_error: :model_load_failed, failed_at: ...}]}
```

### CLI Health Check

```bash
# Human-readable
mix agent_db.doctor

# JSON for automation
mix agent_db.doctor --json
# => {"checks":{"db":true,"models":true,"queue":true,"pubsub":true,"inference_provider":true},"status":"healthy"}
```

**Exit Codes**: `0` = healthy/degraded, non-zero = database unreachable only.

### Recommended Alert Thresholds

| Metric | Warning | Critical | Source |
|--------|---------|----------|--------|
| `health_check.checks.db` | — | `false` | `mix agent_db.doctor --json` |
| `health_check.checks.models` | — | `false` | `mix agent_db.doctor --json` |
| `model_status.embedding.state` | `:loading` > 60s | `:failed` | `AgentDb.model_status/0` |
| `model_status.llm.state` | `:loading` > 60s | `:failed` | `AgentDb.model_status/0` |
| `queue_stats.pending` | > 100 | > 500 | `AgentDb.queue_stats/0` |
| `queue_detail.oldest_pending_ms` | > 60_000 | > 300_000 | `AgentDb.queue_detail/1` |
| `queue_stats.failed` | > 0 | > 10 | `AgentDb.queue_stats/0` |
| `index_coverage.vector.available` | — | `false` | `AgentDb.index_coverage/0` |

## Error Taxonomy (Shared Across All Transports)

Every error response on every transport includes a `code` from this bounded taxonomy. Operators can alert on codes without parsing messages.

### Error Code Categories

| Category | Codes | HTTP Status | Retryable |
|----------|-------|-------------|-----------|
| **Missing** | `not_found`, `no_memory`, `assertion_not_found` | 404 | No |
| **Caller Error** | `invalid_mode`, `invalid_uri`, `invalid_query`, `invalid_limit`, `invalid_document`, `invalid_memory`, `invalid_memory_type`, `invalid_session`, `invalid_user_id`, `invalid_scope`, `invalid_json`, `invalid_argument`, `invalid_payload`, `not_a_memory_uri`, `is_root`, `missing_argument`, `unknown_event`, `unknown_tool`, `unsafe_path`, `unsupported_entry`, `unexpected_entry`, `empty` | 422 | No |
| **Auth** | `unauthorized` | 401 | No |
| **Rate Limit** | `rate_limited` | 429 | Yes (backoff) |
| **Payload Too Large** | `too_large`, `too_big`, `too_many_entries` | 413 | No |
| **Retryable Unavailable** | `model_loading`, `background_jobs_pending`, `vector_index_unavailable`, `storage_busy` | 503 | Yes |
| **Server Failure** | `inference_failed`, `inference_timeout`, `model_load_failed`, `download_failed`, `background_jobs_failed`, `hybrid_leg_timeout`, `hybrid_leg_failed`, `enqueue_failed`, `storage_error`, `provider_unreachable`, `error` | 500 | Depends |

### Transport Mapping

| Transport | Error Shape | Code Field |
|-----------|-------------|------------|
| Elixir API | `{:error, reason}` | `Observability.error_code(reason)` |
| CLI | stderr JSON/text | `Observability.error_code(reason)` |
| MCP | `{"jsonrpc":"2.0","error":{"code":...,"message":...,"data":{"reason":"..."}}}` | `data.reason` |
| WebSocket | `{"event":"v1.*","payload":{"error":true,"reason":...,"code":...}}` | `code` |
| HTTP REST | `{"error":...,"code":...}` | `code` |
| Structured Log | `Logger.metadata` | `reason` field |
| Telemetry | `:telemetry` metadata | `outcome: :error`, `operation` |

### Alerting on Error Codes

```promql
# Alert on provider unavailability
increase(agent_db_operation_total{code="provider_unreachable"}[5m]) > 0

# Alert on model load failures
increase(agent_db_model_total{outcome="error",code="model_load_failed"}[5m]) > 0

# Alert on queue backpressure (failed jobs)
increase(agent_db_job_total{outcome="error"}[5m]) > 10
```

## Trace Correlation

All operations propagate W3C `traceparent` headers:
- **HTTP**: `traceparent` header
- **WebSocket**: Top-level `traceparent` field or inside `opts.traceparent`
- **MCP**: Inside `opts.trace_context` or HTTP header
- **Background Jobs**: Trace context retained from enqueueing operation

Use `trace_id` in logs/telemetry to correlate a request across transports and into background job execution.

## Verification Commands

```bash
# Full health check (JSON)
mix agent_db.doctor --json

# Model status
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.model_status())"

# Queue stats
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.queue_stats())"

# Queue detail (failed jobs)
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.queue_detail(20))"

# Storage stats
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.storage_stats())"

# Cache stats
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.cache_stats())"

# Index coverage
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.index_coverage())"

# Recent errors
elixir -e "Application.ensure_all_started(:agent_db); IO.inspect(AgentDb.recent_errors(20))"
```