# AgentDb

**Embedded offline context store for AI agents** — a persistent URI-addressed tree with vector search, LLM summarization, and optional WebSocket API.

## Features

- **Hierarchical context tree** — `viking://` URIs with `resources/`, `user/{id}/memories`, `user/{id}/resources`, `user/{id}/skills`, `peers/`
- **Layered content** — Full content (L2) with optional caller-supplied or LLM-generated abstract (L0) and overview (L1)
- **Keyword search** — Case-insensitive substring search over content/abstract/overview with subtree scoping
- **Vector search** — Semantic similarity search via sqlite-vec (HNSW index) with 384-dim embeddings
- **Hybrid search** — Reciprocal Rank Fusion of keyword + vector results
- **LLM summarization** — Auto-generates abstract/overview using local Phi-3-mini (configurable)
- **Async writes** — Immediate acknowledgement, background embedding/summarization jobs
- **Sessions** — Append-only message lists with commit-to-context-tree
- **WebSocket API** — Phoenix Channel at `/api` with `v1.*` events, optional Bearer auth
- **Fully local** — No external dependencies at runtime (models cached locally)

## Installation

```elixir
def deps do
  [
    {:agent_db, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Start the application (usually in your supervision tree)
{:ok, _} = Application.ensure_all_started(:agent_db)

# Write a document
:ok = AgentDb.write("viking://resources/my_project/readme.md", "# My Project\n\nHello world!")

# Read content, abstract, overview
{:ok, content} = AgentDb.read("viking://resources/my_project/readme.md")
{:ok, abstract} = AgentDb.abstract("viking://resources/my_project/readme.md")  # LLM-generated if not provided
{:ok, overview} = AgentDb.overview("viking://resources/my_project/readme.md")  # LLM-generated if not provided

# Search
{:ok, results} = AgentDb.search("hello", mode: :keyword)    # Keyword search
{:ok, results} = AgentDb.search("greeting", mode: :vector)   # Semantic search
{:ok, results} = AgentDb.search("hello", mode: :hybrid)      # Combined

# Sessions
{:ok, session_id} = AgentDb.create_session()
:ok = AgentDb.append_message(session_id, :user, "Remember this")
:ok = AgentDb.append_message(session_id, :assistant, "Got it")
{:ok, messages} = AgentDb.get_session(session_id)
{:ok, uri} = AgentDb.commit_session(session_id, "viking://user/me/memories/session-1")
```

## Configuration

All configuration via `Application.put_env/3` or `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

config :agent_db,
  # Data directory (default: ./data)
  data_dir: "/path/to/data",
  
  # Model cache directory (default: ./models)
  model_cache_dir: "/path/to/models",
  
  # Embedding model (default: all-MiniLM-L6-v2, 384-dim)
  embedding_model: "sentence-transformers/all-MiniLM-L6-v2",
  embedding_model_url: "https://huggingface.co/.../model.safetensors",
  
  # LLM model (default: Phi-3-mini-4k-instruct, 3.8B)
  llm_model: "microsoft/Phi-3-mini-4k-instruct",
  llm_model_url: "https://huggingface.co/.../model-q4_k_m.gguf",
  
  # Write mode (default: true = async)
  async_writes: true,
  
  # Job worker pool size (default: CPU cores)
  job_workers: 4,
  
  # EXLA backend: :cpu, :cuda, :rocm
  exla_backend: :cpu,
  
  # HTTP/WebSocket API (default: true)
  http_enabled: true,
  http_port: 4000,
  
  # Optional Bearer token auth
  http_auth: false,
  http_auth_tokens: ["token1", "token2"]
```

### Environment Variables

All config can be set via environment variables:

| Config | Env Var | Default |
|--------|---------|---------|
| `data_dir` | `AGENT_DB_DATA_DIR` | `./data` |
| `model_cache_dir` | `AGENT_DB_MODEL_CACHE_DIR` | `./models` |
| `embedding_model` | `AGENT_DB_EMBEDDING_MODEL` | `all-MiniLM-L6-v2` |
| `embedding_model_url` | `AGENT_DB_EMBEDDING_MODEL_URL` | HF URL |
| `llm_model` | `AGENT_DB_LLM_MODEL` | `Phi-3-mini-4k-instruct` |
| `llm_model_url` | `AGENT_DB_LLM_MODEL_URL` | HF URL |
| `async_writes` | `AGENT_DB_ASYNC_WRITES` | `true` |
| `job_workers` | `AGENT_DB_JOB_WORKERS` | CPU cores |
| `exla_backend` | `AGENT_DB_EXLA_BACKEND` | `cpu` |
| `http_enabled` | `AGENT_DB_HTTP_ENABLED` | `true` |
| `http_port` | `AGENT_DB_HTTP_PORT` | `4000` |
| `http_auth` | `AGENT_DB_HTTP_AUTH` | `false` |
| `http_auth_tokens` | `AGENT_DB_HTTP_AUTH_TOKENS` | `[]` |

## WebSocket API

Connect to `ws://localhost:4000/api` and send messages:

```json
// Write
{"event": "v1.write", "payload": {"uri": "viking://resources/foo.md", "content": "Hello", "opts": {}}}

// Read
{"event": "v1.read", "payload": {"uri": "viking://resources/foo.md"}}

// Search
{"event": "v1.search", "payload": {"term": "hello", "opts": {"mode": "hybrid", "top_k": 10}}}

// Session
{"event": "v1.create_session", "payload": {}}
{"event": "v1.append_message", "payload": {"session_id": "...", "role": "user", "content": "hi"}}
{"event": "v1.get_session", "payload": {"session_id": "..."}}
{"event": "v1.commit_session", "payload": {"session_id": "...", "destination_uri": "viking://user/me/memories/s"}}

// Model status
{"event": "v1.model_status", "payload": {}}
```

With auth enabled, include `Authorization: Bearer <token>` header on connect.

## Architecture

```
AgentDb.Application
├── Cache.Owner (ETS: node_cache, dir_cache)
├── Store.Writer (single SQLite write connection)
├── Store.Reader (pooled SQLite read connections)
├── ML.ModelManager (GenServer: embedding + LLM models)
├── Workers.EmbeddingWorker (pool: processes embed jobs)
├── Workers.SummarizationWorker (pool: processes summarize jobs)
├── JobQueue (SQLite-backed, optimistic locking)
└── WebEndpoint + WebSocket + WebChannel (Phoenix Channel API)
```

- **SQLite** is the single source of truth (WAL mode, FK constraints)
- **ETS caches** are disposable read-through layers, invalidated on every write
- **JobQueue** uses optimistic locking (single-writer serialization)
- **Models** loaded lazily on first inference, cached locally

## Models

| Model | Role | Size | Format |
|-------|------|------|--------|
| `all-MiniLM-L6-v2` | Embeddings | ~90MB | safetensors |
| `Phi-3-mini-4k-instruct` | Summarization | ~2.3GB | GGUF (q4) |

Models auto-download on first use to `model_cache_dir`. Can be pre-placed manually.

## Requirements

- Elixir 1.20+
- EXLA (CPU/GPU via XLA)
- Bumblebee, Nx
- Phoenix, Phoenix.Channel
- SQLite3 (via exqlite)

## License

MIT