## Context

Current `AgentDb` is a single-process Elixir library with:
- SQLite (WAL mode) as source of truth for documents, sessions, commit metadata
- ETS caches (`node_cache`, `dir_cache`) invalidated on every write
- Single-writer GenServer (`Store.Writer`) serializing all mutations
- Pooled reader GenServer (`Store.Reader`) for concurrent reads
- `Cache.Invalidate` drops affected cache entries on write/rm
- Public API in `AgentDb` module: write/read/abstract/overview/list/tree/rm/search + session ops

No network layer, no background jobs, no ML dependencies.

## Goals / Non-Goals

**Goals:**
- Add vector search via `sqlite-vec` with HNSW index
- Add async LLM summarization (L0/L1) via Bumblebee/EXLA
- Add PhoenixGenApi WebSocket gateway for remote access
- Keep SQLite as single source of truth; ETS remains disposable cache
- Background job processor using SQLite-backed queue (Oban or custom)
- Model manager handles download/cache/load of embedding + LLM models
- All new components supervised under `AgentDb.Application`
- Configurable async/sync write mode, CPU/GPU backend, model selection

**Non-Goals:**
- Distributed/clustered deployment (single-node only)
- Multiple embedding models simultaneously
- Fine-grained per-document model selection
- Full RAG pipeline (retrieval + generation) — only retrieval + summarization
- Authentication built-in (delegated to PhoenixGenApi plugs if needed)

## Decisions

### 1. Vector Search: sqlite-vec over in-memory HNSW

**Decision**: Use `sqlite-vec` virtual table extension for vector storage and HNSW indexing.

**Rationale**: 
- Single SQLite file remains source of truth (no separate vector DB)
- `sqlite-vec` provides native HNSW index with `vec0` virtual table
- Persists across restarts — no re-embedding needed
- JOIN with `nodes` table for hybrid search in single query
- Mature, used in production (e.g., `llama.cpp`, `sqlite-vec` Python bindings)

**Alternatives considered**:
- In-memory HNSW (exla/hnsw): Fast but loses index on restart; requires full re-embed on recovery
- Qdrant/Chroma: Operational complexity; separate process; network latency
- pgvector: Requires PostgreSQL; violates embedded SQLite design

**Implementation**: 
```
CREATE VIRTUAL TABLE vec_nodes USING vec0(
  embedding float[384],
  uri TEXT PRIMARY KEY
);
-- HNSW index created automatically by vec0
-- Search: SELECT uri, vec_distance_cosine(embedding, ?) AS dist FROM vec_nodes ORDER BY dist LIMIT ?
```

### 2. Background Jobs: Custom SQLite Queue over Oban

**Decision**: Implement a lightweight SQLite-backed job queue instead of Oban.

**Rationale**:
- Oban requires PostgreSQL; adds heavy dependency for simple needs
- Our queue needs: enqueue, dequeue (with locking), retry with backoff, persistence
- SQLite WAL + `SELECT ... FOR UPDATE SKIP LOCKED` pattern works well
- ~200 lines of Elixir vs. heavy Oban + PostgreSQL

**Queue Schema**:
```sql
CREATE TABLE job_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,           -- 'embed' | 'summarize_abstract' | 'summarize_overview'
  payload TEXT NOT NULL,        -- JSON: {uri, content, ...}
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | running | done | failed
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 5,
  scheduled_at INTEGER NOT NULL, -- unix ms
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_job_queue_status_sched ON job_queue(status, scheduled_at);
```

**Worker Pool**: `GenServer` pool (configurable size, default `System.schedulers_online()`). Each worker:
1. `SELECT * FROM job_queue WHERE status='pending' AND scheduled_at <= ? ORDER BY scheduled_at LIMIT 1 FOR UPDATE SKIP LOCKED`
2. Update status → `running`, `attempts + 1`
3. Execute work (embed/summarize)
4. On success: update status → `done`, update `nodes` + `vec_nodes`
5. On failure: if `attempts < max_attempts`, reschedule with exponential backoff; else → `failed`

### 3. Model Management: Bumblebee + EXLA with Lazy Loading

**Decision**: `ModelManager` GenServer owns model state; downloads on first use; serves inference via `handle_call`.

**Models**:
| Model | Role | Size | Dim/Params | Quantization |
|-------|------|------|------------|--------------|
| `sentence-transformers/all-MiniLM-L6-v2` | Embeddings | ~90MB | 384 | fp32 (CPU) / int8 (GPU) |
| `microsoft/Phi-3-mini-4k-instruct` | Summarization | ~2.3GB | 3.8B | q4_k_m (CPU) / fp16 (GPU) |

**Loading Strategy**:
- Startup: `ModelManager` starts, checks cache dir for model files
- First inference request: if not loaded, load into EXLA (blocks caller)
- Configurable: `eager_load: true` loads at startup
- Cache dir: `:agent_db, :model_cache_dir` (default `~/.cache/agent_db/models`)

**Inference API**:
```elixir
# Embedding
ModelManager.embed(texts) → {:ok, [%Nx.Tensor{}]} | {:error, reason}

# Summarization (chat template)
ModelManager.summarize(prompt, max_tokens: 256) → {:ok, text} | {:error, reason}
```

**Prompt Templates** (configurable):
- Abstract: "Summarize the following text in ONE sentence capturing the core point:\n\n{content}\n\nAbstract:"
- Overview: "Provide a concise structured overview (3-5 sentences) of the following text:\n\n{content}\n\nOverview:"

### 4. HTTP API: PhoenixGenApi with Versioned Functions

**Decision**: Use `PhoenixGenApi` (WebSocket-based) for all remote operations. Functions versioned as `v1.*`.

**Gateway Setup**:
```elixir
# In AgentDb.Application supervision tree
{PhoenixGenApi.Gateway, 
  fun_config: AgentDb.WebAPI.fun_config(),
  otp_app: :agent_db,
  endpoint: AgentDb.WebEndpoint}
```

**Function Config** (subset):
```elixir
def fun_config do
  [
    # Documents
    {"v1.write", AgentDb, :write, [uri: :string, content: :string, opts: :map]},
    {"v1.read", AgentDb, :read, [uri: :string]},
    {"v1.abstract", AgentDb, :abstract, [uri: :string]},
    {"v1.overview", AgentDb, :overview, [uri: :string]},
    {"v1.list", AgentDb, :list, [uri: :string]},
    {"v1.tree", AgentDb, :tree, [uri: :string, depth: :integer]},
    {"v1.rm", AgentDb, :rm, [uri: :string]},
    
    # Search
    {"v1.search", AgentDb, :search, [term: :string, opts: :map]},
    # opts: mode (:keyword | :vector | :hybrid), scope, top_k, hybrid_weights
    
    # Sessions
    {"v1.create_session", AgentDb, :create_session, []},
    {"v1.append_message", AgentDb, :append_message, [session_id: :string, role: :atom, content: :string]},
    {"v1.get_session", AgentDb, :get_session, [session_id: :string]},
    {"v1.commit_session", AgentDb, :commit_session, [session_id: :string, destination_uri: :string, opts: :map]},
    
    # Model status
    {"v1.model_status", AgentDb.WebAPI, :model_status, []}
  ]
end
```

**Phoenix Endpoint**: Minimal — only WebSocket transport, no HTTP routes.
```elixir
defmodule AgentDb.WebEndpoint do
  use Phoenix.Endpoint, otp_app: :agent_db
  socket "/api", AgentDb.WebSocket, websocket: [compress: true]
end
```

### 5. Async Write Path: Immediate Ack + Job Enqueue

**Decision**: `AgentDb.write/3` returns `:ok` after SQLite persist; enqueues embed + summarize jobs.

**Flow**:
```
AgentDb.write(uri, content, opts)
  → persist_doc() → SQLite (nodes table)
  → Invalidate.on_write(uri)
  → :ok returned to caller
  → JobQueue.enqueue(:embed, %{uri, content})
  → if opts[:abstract] == nil: JobQueue.enqueue(:summarize_abstract, %{uri, content})
  → if opts[:overview] == nil: JobQueue.enqueue(:summarize_overview, %{uri, content})
```

**Cache Behavior**: 
- Write invalidates cache (existing behavior)
- Next read fetches from SQLite (has content, no abstract/overview yet)
- `abstract/1` and `overview/1` return fallbacks until summarization jobs complete
- When summarization job completes: updates `nodes` row, invalidates cache
- Next read gets LLM-generated content

**Sync Mode** (configurable): `write/3` waits for all jobs to complete (with timeout).

### 6. Search API Evolution

**Decision**: Extend `AgentDb.search/2` with `mode` option; default `:keyword` for backward compatibility.

```elixir
def search(term, opts \\ []) do
  mode = Keyword.get(opts, :mode, :keyword)
  case mode do
    :keyword  -> keyword_search(term, opts)
    :vector   -> vector_search(term, opts)
    :hybrid   -> hybrid_search(term, opts)
  end
end
```

**Vector Search**: Uses `ModelManager.embed/1` for query embedding, then `sqlite-vec` KNN.

**Hybrid Search**: Reciprocal Rank Fusion (RRF) with configurable weights:
```
score = w_keyword * (1 / (rank_keyword + k)) + w_vector * (1 / (rank_vector + k))
```
Default: `k=60`, `w_keyword=0.5`, `w_vector=0.5`.

### 7. Configuration

```elixir
# config/runtime.exs
config :agent_db,
  data_dir: "/path/to/data",
  model_cache_dir: "/path/to/models",
  embedding_model: "sentence-transformers/all-MiniLM-L6-v2",
  embedding_model_url: "https://huggingface.co/.../resolve/main/model.safetensors",
  llm_model: "microsoft/Phi-3-mini-4k-instruct",
  llm_model_url: "https://huggingface.co/.../resolve/main/model-q4_k_m.gguf",
  async_writes: true,
  job_workers: System.schedulers_online(),
  exla_backend: :cpu,  # or :cuda, :rocm
  http_enabled: true,
  http_port: 4000,
  http_auth: false,
  http_auth_tokens: []
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `sqlite-vec` compilation fails on some platforms | Pre-compiled NIF via `exla` pattern; fallback to pure Elixir HNSW if needed |
| LLM summarization slow on CPU (>5s/doc) | Configurable timeout; async default; q4 quantization; batch summarization |
| Model download fails (network, disk space) | Retry with backoff; clear error messages; allow manual model placement |
| Memory pressure from EXLA + models + SQLite cache | Configurable worker pool size; streaming inference; memory limits via `Nx.Defn.Options` |
| WebSocket connection handling under load | PhoenixGenApi built-in backpressure; connection limits; metrics |
| Schema migration for existing users | `sqlite-vec` table created idempotently; jobs table added; no breaking schema changes |
| Async writes break caller expectations | Document clearly; provide `async_writes: false` option; test sync mode |
| Background job queue grows unbounded | Max queue size config; backpressure on enqueue; monitoring metrics |

## Migration Plan

1. **Phase 1** (core): Add `sqlite-vec` dependency, `vec_nodes` table, `ModelManager` (embeddings only), `JobQueue`, embedding worker
2. **Phase 2** (summarization): Add LLM model, summarization jobs, update `AgentDb.write` to enqueue jobs, modify `abstract/overview` to return generated content
3. **Phase 3** (search): Implement `vector_search` and `hybrid_search`, extend `search/2` API
4. **Phase 4** (HTTP): Add Phoenix/GenApi deps, `WebEndpoint`, `WebSocket`, `WebAPI`, function config
5. **Phase 5** (polish): Config, docs, tests, benchmark, example app

**Rollback**: Each phase is independent. Disable via config (`http_enabled: false`, `async_writes: false`). Drop `vec_nodes` and `job_queue` tables to revert fully.

## Open Questions

1. **Quantization format for LLM**: GGUF via `llama.cpp` bindings vs. Bumblebee-native safetensors? Bumblebee supports GGUF but EXLA backend may need `llama.cpp` NIF.
2. **Batching embeddings**: Accumulate N texts before `ModelManager.embed/1` call for throughput? Adds latency, improves GPU utilization.
3. **Streaming summarization**: PhoenixGenApi supports streaming replies. Use for long LLM responses?
4. **Hybrid search RRF vs. weighted sum**: RRF is parameter-free; weighted sum needs tuning. Start with RRF.
5. **Metrics/Telemetry**: Which events to emit? `[ :job_enqueued, :job_completed, :embedding_latency, :summarization_latency, :search_latency ]`