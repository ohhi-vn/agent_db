# Architecture

AgentDb is an embedded, offline context store for AI agents. It runs as a single Elixir/OTP application with a SQLite backend, local ML inference, and optional HTTP/MCP/WebSocket transports.

```
┌─────────────────────────────────────────────────────────────────┐
│                        AgentDb Application                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │   PubSub    │  │    Cache    │  │ Observability│              │
│  │  (Phoenix)  │  │   (ETS)     │  │   (Sink)    │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                      │
│  ┌──────▼────────────────▼────────────────▼──────┐              │
│  │              Supervisor (one_for_one)          │              │
│  └──────────────────────┬────────────────────────┘              │
│                         │                                        │
│    ┌────────────────────┼────────────────────┐                  │
│    ▼                    ▼                    ▼                  │
│ ┌───────┐           ┌─────────┐          ┌─────────┐           │
│ │Storage│           │Inference│          │Transport│           │
│ │Adapter│           │Adapter  │          │Adapter  │           │
│ └───┬───┘           └────┬────┘          └────┬────┘           │
│     │                    │                    │                  │
│     ▼                    ▼                    ▼                  │
│  SQLite DB            Local Models         HTTP/MCP/WS         │
│  (Source of Truth)    (Embedding + LLM)   (Optional)           │
└─────────────────────────────────────────────────────────────────┘
```

## Component Boundaries

### 1. Context Store (`AgentDb.Application.Documents`, `AgentDb.Store`)

**Responsibility**: Persistent URI-addressed tree with layered content (L2 full content, L0 abstract, L1 overview), keyword search, find/grep navigation, subtree removal.

**Key Modules**:
- `AgentDb.Store.SQLite` — Low-level SQLite operations (single writer connection)
- `AgentDb.Store.Writer` / `Reader` — Serialized write / concurrent read paths
- `AgentDb.Store.Nodes` — URI parsing, tree operations
- `AgentDb.Application.Documents` — Public document workflows (write, read, list, tree, rm)
- `AgentDb.Cache` — ETS read caches (disposable, rebuilt on restart)

**Data Flow (Write Path)**:
```
AgentDb.write/3
    │
    ▼
Documents.write/3
    │
    ├──► SQLite: INSERT document + enqueue jobs + retire the
    │           URI's previous vector row (one transaction)
    │
    ├──► Cache: invalidate subtree
    │
    ├──► PubSub: broadcast :written
    │
    └──► Returns :ok (before embeddings/summaries complete)
```

**Data Flow (Read Path)**:
```
AgentDb.read/1
    │
    ▼
Documents.read/1
    │
    ├──► Cache hit? ──Yes──► Return content
    │
    └──No
        │
        ▼
    SQLite: SELECT content
        │
        ▼
    Cache: populate + Return content
```

**Durability Guarantees**:
- SQLite is the source of truth for the node store, the memories, the sessions,
  the commit bookkeeping, and the job queue; ETS caches and the vector index are
  disposable
- A removal clears the authoritative stores atomically — node store, memories,
  commit bookkeeping, job queue, caches
- The vector index is *derived*, so a removal does not clear it in the same
  step. What removal does guarantee is that the URI stops being searchable
  immediately, because every vector search joins back against the node store. A
  row naming a removed URI is inert from the moment the removal commits, and a
  standing job reclaims it afterwards. See
  [Vector index drift](SETUP.md#vector-index-drift)
- A write retires the URI's previous vector in the same transaction, so a
  re-written document is never ranked on content it no longer has
- Full recovery of the authoritative stores from SQLite alone after restart

### 2. Memory System (`AgentDb.Application.Memories`, `AgentDb.Store.Memories`)

**Responsibility**: Typed durable facts under `viking://user/{id}/memories/{type}/{name}` with provenance, confidence, supersession, and candidate promotion workflow.

**Types**: `profile`, `preferences`, `entities`, `events`, `experiences`

**Key Features**:
- Deterministic (no model participation)
- Revision by URI (old value superseded, still inspectable)
- Candidate queue for low-confidence/duplicate memories
- Semantic search via embeddings (async, never generates summaries)

### 3. Inference Pipeline (`AgentDb.Core.Inference`, `AgentDb.Adapters.Inference`)

**Responsibility**: Local embedding and summarization models. Provider abstraction allows swapping backends.

**Providers**:
- `AgentDb.Adapters.Inference` (Local via Bumblebee/EXLA/EMLX) — Default
- `AgentDb.Adapters.Inference.Ollama` — Remote Ollama
- `AgentDb.Adapters.Inference.OpenAICompatible` — Remote OpenAI-compatible

**Containment at the composition root** (`AgentDb.Runtime`): the runtime is
where a vector-index answer is admitted into the rest of the store, so it is
also where a failure is contained. A native engine — sqlite-vec is a loadable
extension, and any that follows will be a NIF — can raise, and a raise inside a
`GenServer.call` is not an error a caller can act on; it is an exit that kills
the process the operator was already relying on. `Runtime.vector_search/3`,
`vector_put/3`, and `vector_stats/0` therefore convert every failure into the
store's existing error contract: an error tuple carrying a classification,
never an exception, and never a new failure class. Overload maps to the same
retryable `:vector_index_unavailable` the store already reports for an index it
cannot reach — never to a distinct permanent failure — and a worker that sees
it defers rather than failing. This same containment is why the boundaries test
allows a workflow to name `Runtime` and no other provider.

**Model Roles**:
- `embedding` — Vector embeddings for search
- `llm` — Summarization (abstract/overview generation)

**Configuration** (via `AgentDb.Config`):
- `embedding_model` / `embedding_model_url`
- `llm_model` / `llm_model_url` / `llm_chat_template`
- `ml_backend` — `auto` | `exla` | `emlx` (EMLX only on Apple Silicon)
- `exla_backend` — `cpu` | `cuda` | `rocm`
- `inference_concurrency` — Max concurrent inference runs
- `inference_provider` — `:local` | `:ollama` | `:openai_compatible` | custom module

**Loading Behavior**:
- Models download on first use (cached to `model_cache_dir`)
- Lazy loading with `model_load_grace_ms` (default 10s) timeout
- `AgentDb.model_status/0` reports `:loading` | `:ready` | `:failed` | `:idle`
- Load failures don't disable the store; retry on next use

### 4. Background Job Queue (`AgentDb.JobQueue`, `AgentDb.Workers`)

**Responsibility**: Durable SQLite-backed queue for embedding generation, summarization, and vector-index reclamation.

**Job Kinds**:
- `:embed` — Generate vector embedding for a document
- `:summarize_abstract` — Generate L0 abstract
- `:summarize_overview` — Generate L1 overview
- `:reclaim_vector_index` — Delete index rows naming URIs the store no longer
  holds. A *standing* job: the store schedules one at boot, not one per write,
  and it is counted by kind rather than by URI because it belongs to no
  subtree. An idle store defers on a cadence rather than scanning

**Worker Pools** (configured via `job_workers`, default: CPU cores):
- `AgentDb.Workers.Embedding` — One pool
- `AgentDb.Workers.Summarization` — One pool
- `AgentDb.Workers.VectorReclaim` — One worker, not a pool: it claims a single
  global job, so a pool would be several processes contending for one row

**Processing Guarantees**:
- Jobs survive restart (rows in SQLite)
- Exponential backoff retry (1s, 2s, 4s... capped at 5min)
- Deferred jobs (model loading) don't consume retry budget
- Failed jobs distinguishable from deferred; attempt count preserved across restarts
- Unknown job kinds fail fast with classified reason

**Job Lifecycle**:
```
Write → enqueue_many() → pending
    │
    ▼ (Worker claims)
running → complete() → done
    │
    ├──► fail() → retry (attempts < max) → pending (backoff)
    │
    └──► fail() → attempts exhausted → failed (classified reason)
```

### 5. Sessions (`AgentDb.Application.Sessions`, `AgentDb.Store.Sessions`)

**Responsibility**: Append-only message lists persisted in SQLite, commit to context tree as single document.

**Idempotency**: Commit is idempotent per (session, destination). Re-commit of unchanged session → `{:ok, :unchanged}`. If destination removed, re-commit restores it.

### 6. Skills (`AgentDb.Application.Skills`, `AgentDb.Skills.Source`)

**Responsibility**: Import skill folders (with `SKILL.md` at root) into `viking://user/{id}/skills/{name}`.

**Constraints**:
- 500 files / 5MB expanded per import
- Atomic replacement (same name = full replace)
- Refuses: unsafe paths, symlinks, non-UTF-8, missing SKILL.md, over limits

### 7. Data Portability (`AgentDb.Application.DataTransfer`)

**Responsibility**: Export/import tar archives (documents + caller layers, memory provenance, sessions).

**Import Validation**: Traversal, symlink, non-UTF-8, oversize, corrupt, newer format → refuse entire archive.

**Merge Semantics**: Missing created, present revised, colliding sessions skipped, nothing outside deleted. Embeddings/summaries regenerate via job queue.

### 8. Transport Layer (`AgentDb.Core.Transport`, `AgentDb.Adapters.Phoenix`)

**Optional**: Enabled via `http_enabled` (default true, false in test).

**Surfaces**:
1. **HTTP REST** (`/api/v1/*`) — JSON API with Bearer auth option
2. **MCP Streamable HTTP** (`POST /mcp`) — MCP tools/list/call over HTTP
3. **WebSocket** (`ws://host:port/api`) — `v1.*` events with `traceparent` propagation

**Authentication**:
- Default: No auth, loopback bind only (`127.0.0.1:6060`)
- Opt-in: `AGENT_DB_HTTP_AUTH=true` + `AGENT_DB_HTTP_AUTH_TOKENS=token1,token2`
- LAN: `AGENT_DB_HTTP_IP=0.0.0.0` (only with Bearer enabled)

**Trust Boundary**: Loopback-only default means any local process can read/write. Production beyond loopback requires Bearer auth and network isolation.

## Deployment Topology

```
┌──────────────────────────────────────────────────────────────┐
│                    Single Node (BEAM)                         │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │  HTTP/WS     │    │   Workers    │    │   Inference  │   │
│  │  (Phoenix)   │◄───│  (Embedding, │◄───│  (Bumblebee/  │   │
│  │  :6060       │    │   Summary)   │    │   EXLA/EMLX) │   │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘   │
│         │                   │                   │             │
│         │           ┌───────▼───────┐           │             │
│         └──────────►│   Job Queue   │◄──────────┘             │
│                     │   (SQLite)    │                         │
│                     └───────┬───────┘                         │
│                             │                                 │
│                     ┌───────▼───────┐                         │
│                     │  SQLite DB    │                         │
│                     │  (WAL mode)   │                         │
│                     └───────────────┘                         │
└──────────────────────────────────────────────────────────────┘
```

**Single-Node Model**: No BEAM clustering/distribution. PubSub is local only. Horizontal scaling not supported.

**Concurrency Knobs**:
| Setting | Env Var | Default | Controls |
|---------|---------|---------|----------|
| `job_workers` | `AGENT_DB_JOB_WORKERS` | CPU cores | Embedding + summarization parallelism |
| `inference_concurrency` | (app env only) | CPU cores | Max concurrent inference runs |
| `async_writes` | `AGENT_DB_ASYNC_WRITES` | `true` | Write waits for jobs or returns immediately |

**Directories**:
| Setting | Env Var | Default |
|---------|---------|---------|
| `data_dir` | `AGENT_DB_DATA_DIR` | `./data` (holds `agent_db.db`) |
| `model_cache_dir` | `AGENT_DB_MODEL_CACHE_DIR` | `./models` |

## Spec Cross-References

| Capability Spec | Key Requirements |
|-----------------|------------------|
| `context-store` | URI tree, layered content, write path, keyword search, subtree removal, offline operation |
| `memory` | Typed memories, provenance, candidates, conflicts |
| `vector-search` | Embedding, hybrid search, index coverage |
| `inference-providers` | Provider abstraction, local/remote, model status |
| `runtime-observability` | Telemetry, traces, redacted logs, error taxonomy |
| `admin-dashboard` | `/admin` console realtime updates, model/queue/health/status |
| `http-api` | REST, MCP, WebSocket, auth |
| `agent-tooling` | OpenCode/Zed MCP integration |
| `llm-summarization` | Async L0/L1 generation with fallbacks |
| `data-portability` | Export/import tar archives |

## Code Entry Points

| Component | Primary Module | Public Facade |
|-----------|----------------|---------------|
| Documents | `AgentDb.Application.Documents` | `AgentDb.write/3`, `read/1`, `list/1`, `tree/2`, `rm/1` |
| Search | `AgentDb.Application.Search` | `AgentDb.search/2`, `find/2`, `grep/2` |
| Memory | `AgentDb.Application.Memories` | `AgentDb.remember/3`, `recall/1`, `forget/1`, `promote_memory/1` |
| Sessions | `AgentDb.Application.Sessions` | `AgentDb.create_session/0`, `append_message/3`, `commit_session/3` |
| Skills | `AgentDb.Application.Skills` | `AgentDb.import_skills/2` |
| Data Transfer | `AgentDb.Application.DataTransfer` | `AgentDb.export_data/2`, `import_data/2` |
| Status | `AgentDb.Application.Status` | `AgentDb.health_check/0`, `model_status/0`, `queue_stats/0` |
| Job Queue | `AgentDb.JobQueue` | Internal (enqueue/dequeue/complete/fail) |
| Inference | `AgentDb.Adapters.Inference` | Internal (embed/summarize/model_status) |
| Cache | `AgentDb.Cache` | Internal (ETS read caches) |
| Observability | `AgentDb.Observability` | `recent_errors/1`, `operation_stats/0`, `timed/3` |
| Runtime Config | `AgentDb.Config` | All `AGENT_DB_*` env vars |
| Subscriptions | `AgentDb.Subscriptions` | `AgentDb.subscribe/1`, `unsubscribe/1` |