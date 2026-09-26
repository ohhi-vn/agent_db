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
- **Memory** — Typed, durable facts under `viking://user/memories/` with confidence, provenance, and supersession; recall and forgetting without a model
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

# Memory
{:ok, uri} = AgentDb.remember("viking://user/memories/preferences/language", "prefers Elixir over Go",
       confidence: 0.9, source: session_id)
{:ok, memories} = AgentDb.recall(type: :preferences)
{:ok, [memory]} = AgentDb.recall("viking://user/memories/preferences/language")
:ok = AgentDb.forget("viking://user/memories/preferences/language")
```

## Memory

`agent_db` is a library linked into your agent's own process, so **the caller is
the extractor**: `remember/3` records a fact your agent has already decided is
durable. No language model participates in any memory operation, so the whole
surface is deterministic and works with no model loaded.

Memories live under `viking://user/memories/<type>/<name>`. The `<type>` segment
is the memory's type, drawn from a fixed taxonomy:

| Type | Holds |
|------|-------|
| `profile` | name, language, timezone, occupation |
| `preferences` | coding style, UI, communication |
| `entities` | people, companies, projects, repositories, products |
| `events` | "migrated X to Elixir", "released 1.2" |
| `experiences` | task / approach / result / lessons |

A memory's type is derived from its URI rather than passed as an option, so a
memory's stated type can never contradict where it is filed, and `recall` by type
is a subtree query.

### The URI is the memory's identity

Recording at a URI that already holds a memory **revises** it. Recording at a
different URI **adds** a fact — coexistence is expressed by URI choice, not by a
flag.

```elixir
{:ok, _} = AgentDb.remember("viking://user/memories/preferences/language",
       "user uses Go", confidence: 0.6)

{:ok, _} = AgentDb.remember("viking://user/memories/preferences/language",
       "user moved the project to Elixir", confidence: 0.9)

# One active value...
{:ok, [active]} = AgentDb.recall("viking://user/memories/preferences/language")
active.value
#=> "user moved the project to Elixir"

# ...and the superseded value is retained, not erased.
{:ok, history} = AgentDb.recall(uri: "viking://user/memories/preferences/language",
       include_superseded: true)

prior = Enum.find(history, &(&1.status == :superseded))
prior.value
#=> "user uses Go"

successor = Enum.find(history, &(&1.id == prior.supersedes))
successor.value
#=> "user moved the project to Elixir"
```

This is what keeps a revised belief from accumulating as a contradiction: the
store resolves to one active value while the history of the change stays
inspectable.

### `remember/3`

```elixir
AgentDb.remember(uri, value, opts \\ [])
```

- `:confidence` — 0.0..1.0, default `0.5` (`AgentDb.default_confidence/0`)
- `:source` — provenance, e.g. the originating session id

Returns `{:ok, uri}`, or an error naming the invalid type
(`{:error, {:invalid_memory_type, type}}`), a URI outside the memories root
(`{:error, {:not_a_memory_uri, uri}}`), or `{:error, :invalid_uri}`.

### `recall/1`

```elixir
AgentDb.recall()                                  # everything, active only
AgentDb.recall("viking://user/memories/events")   # a subtree
AgentDb.recall("viking://user/memories/events/2026-release")  # exactly one
AgentDb.recall(type: :events)                     # a whole type
AgentDb.recall(term: "kubernetes")                # matching values
AgentDb.recall(uri: uri, include_superseded: true) # inspect a revision chain
```

A scope matches the exact URI or anything beneath it, so
`.../preferences` does not also reach a sibling named `preferences-extra`.
Results are ordered by descending confidence; a recall matching nothing returns
`{:ok, []}` rather than an error.

### `forget/1`

```elixir
:ok = AgentDb.forget("viking://user/memories/preferences/language")
{:error, :no_memory} = AgentDb.forget("viking://user/memories/preferences/never-recorded")
```

Forgetting removes the value *and* its provenance, including every superseded
assertion — a tombstone that kept the text would not have forgotten anything.
Supersession, not forgetting, is what preserves history. A URI holding only an
ordinary document is left alone.

### Memories embed, but are not summarized

Recording a memory enqueues **embedding generation only**. L0 abstracts and L1
overviews exist to compress a document large enough that reading it whole is
wasteful; they can say nothing about an atomic fact that its value does not
already say, and generating them would cost two model-dependent jobs and, on a
cold cache, a model load.

Embedding is a different matter — it is what makes a memory reachable by meaning
rather than by substring, and it is why memories become semantically retrievable
with no further work once inference is available. Until then, memories are fully
usable through keyword `search/2` scoped to the memories root.

Memories are ordinary documents: `read/1`, `list/1`, `tree/2` and
`search/2` reach them with no memory-specific path.

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
  
  # HTTP/WebSocket API (default: true; false in :test)
  http_enabled: true,
  
  # Optional Bearer token auth
  http_auth: false,
  http_auth_tokens: ["token1", "token2"]
```

### HTTP listener

The listener is opened in every environment where HTTP is enabled. This depends
on `server: true` being set on the endpoint configuration, which
`config/runtime.exs` does — without it Phoenix starts the endpoint and binds
nothing, and reports that only under a release, so the surface is silently
absent under `mix run` and `iex -S mix`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `AGENT_DB_HTTP_ENABLED` | `true` (`false` in `:test`) | Whether the endpoint is started and serves |
| `AGENT_DB_HTTP_PORT` | `4000` | Port served, and the port used for URL generation |
| `AGENT_DB_HTTP_IP` | `127.0.0.1` | Interface bound |

The port is resolved once, in `config/runtime.exs`, and used for both the
listener and the endpoint's `url:` — so the two cannot disagree. `PORT` is **not**
read; a deployment that sets it must move to `AGENT_DB_HTTP_PORT`.

**The bind defaults to loopback.** The HTTP surface is unauthenticated by design
— it exposes document and memory content, session identifiers and model state —
so it does not land on every interface unless you ask for it. To serve a private
network, set `AGENT_DB_HTTP_IP` to that address and make sure the port is not
exposed more widely than you intend.

```bash
# reachable from other machines on the LAN
AGENT_DB_HTTP_ENABLED=true AGENT_DB_HTTP_IP=0.0.0.0 AGENT_DB_HTTP_PORT=4000 iex -S mix
```

### Known issues on the HTTP surface

The listener is live, and turning it on has made pre-existing breakage in the web
layer visible for the first time — these routes have never been exercised, because
until now nothing was listening:

- **`/admin` returns an error.** `AgentDbWeb.AdminLive` has no `render/1` clause,
  so it cannot render. The operations console is the subject of a separate
  change. If you can reach `/admin` and see an error, that is why.
- **`POST /api/v1/search` returns 500.** The controller passes the search mode as
  a string, `AgentDb.search/2` matches on atoms, and the resulting
  `{:invalid_mode, _}` error is then rendered through `Jason`, which cannot
  encode a bare tuple — so the intended 422 is itself unreachable. Both defects
  predate the listener and are not fixed by it.

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
| `http_enabled` | `AGENT_DB_HTTP_ENABLED` | `true` (`false` in `:test`) |
| `http_ip` | `AGENT_DB_HTTP_IP` | `127.0.0.1` |
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

### Model cache notes

- Downloads are written to a temporary path and renamed into place, so a file
  named `model.safetensors` is always a complete download. Earlier versions
  wrote directly to that path, so a `model.safetensors` left behind by an
  interrupted download can still be truncated. **If model loading fails, delete
  the file and let it re-download** — its presence is the only cache check.
- `exla_backend` (`AGENT_DB_EXLA_BACKEND`) is now applied to the loaded model.
  It previously had no effect. `:cpu` uses Nx's default backend; `:cuda` and
  `:rocm` require a matching `config :exla, clients` entry, and **loading fails
  with an error if none is configured** rather than quietly falling back to CPU.
- If a model cannot be downloaded or loaded, the operation that needed it
  returns `{:error, reason}`. It does not terminate the calling process, and the
  rest of the store keeps working.
- Models load lazily, so a model-dependent call made before the model is ready
  returns `{:error, :model_loading}`. That is distinct from a failure and is
  safe to repeat: the store waits up to `model_load_grace_ms` (default 10s) for
  the load first, which covers a model that is already cached, and only then
  reports `:model_loading`. `model_status/0` reports `state: :loading | :ready
  | :failed | :idle` and stays answerable throughout.

## Requirements

- Elixir 1.20+
- EXLA (CPU/GPU via XLA)
- Bumblebee, Nx
- Phoenix, Phoenix.Channel
- SQLite3 (via exqlite)

## License

MIT