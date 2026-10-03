# AgentDb

**Embedded offline context store for AI agents** — a persistent URI-addressed tree with vector search, LLM summarization, and optional WebSocket API.

## Guides

- [Quickstart](docs/QUICKSTART.md) — 5 minutes to first write, read, search, and health check.
- [Setup](docs/SETUP.md) — full install, configuration, backends, and verification.
- [Usage](docs/USAGE.md) — daily workflows: documents, search, memory, sessions, skills, CLI, MCP, WebSocket.
- [Agent setup](docs/agents.md) — OpenCode and Zed snippets (canonical).

The API reference is generated from the code (`mix docs`) rather than written by
hand, so it cannot drift from the modules it describes.

## Features

- **Hierarchical context tree** — `viking://` URIs with `resources/`, `user/{id}/memories`, `user/{id}/resources`, `user/{id}/skills`, `peers/`
- **Layered content** — Full content (L2) with optional caller-supplied or LLM-generated abstract (L0) and overview (L1)
- **Keyword search** — Case-insensitive substring search over content/abstract/overview with subtree scoping and a bounded `top_k` (default 10, max 200; an out-of-range value is refused rather than ignored)
- **Path discovery (`find`)** — Literal, case-insensitive URI-path match with subtree scoping and bounded results
- **Content inspection (`grep`)** — Literal, case-insensitive L2-only line matches with subtree scoping and bounded excerpts
- **Vector search** — Semantic similarity search via sqlite-vec (HNSW index) with 384-dim embeddings
- **Hybrid search** — Reciprocal Rank Fusion of keyword + vector results
- **LLM summarization** — Auto-generates abstract/overview using a local model (Qwen3-0.6B by default, configurable)
- **Async writes** — Immediate acknowledgement, background embedding/summarization jobs
- **Sessions** — Append-only message lists with commit-to-context-tree
- **Memory** — Typed, durable facts under `viking://user/memories/` with confidence, provenance, and supersession; recall and forgetting without a model
- **Agent Skills** — Import a skill folder or tar archive into `viking://user/{id}/skills/`, from the console or a Mix task, replacing a same-named skill as a whole
- **WebSocket API** — Phoenix Channel at `/api` with `v1.*` events, optional Bearer auth
- **Fully local** — No external dependencies at runtime (models cached locally)
- **Reactive subscriptions** — `AgentDb.subscribe/1` and `v1.subscribe` over `AgentDb.PubSub` with versioned `{:context_changed, uri, kind, version}` events for writes, removals, replacements, and commits; BEAM cluster distribution explicitly deferred
- **Elixir code index** — Structural `.ex`/`.exs` indexing via `Code.string_to_quoted/2` under `viking://resources/<project>/code/` with OTP-aware caller/callee queries, no model required
- **Hex docs** — Locked-version-aware docs under `viking://resources/hex/<package>/<version>/` discovered offline from `mix.lock`
- **BEAM runtime snapshots** — Read-only AgentDb.RuntimeContext.snapshot/0 (apps, supervisors, processes, ETS, memory) with bounds and redaction; never auto-writes
- **Pluggable inference** — Local Nx/Bumblebee default plus opt-in Ollama and OpenAI-compatible adapters behind `AgentDb.Core.Inference`; one `inference_provider` key chooses both which provider serves and the provider kind `model_status/0` reports, and an unreachable remote provider is reported as such rather than as loaded
- **Operations console** — `/admin` reports storage footprint and tree composition, cache and BEAM memory sizes, vector-index coverage, per-role model state (load duration, latency, in-flight, provider health), durable queue depth with failed jobs and their classified reasons, node uptime and process counts, and a bounded list of recent operational errors

## Installation

```elixir
def deps do
  [
    {:agent_db, "~> 0.1.0"}
  ]
end
```

MIT licensed; the terms are in [LICENSE](LICENSE).

Full setup (directories, environment, listener, auth, backends): [Setup](docs/SETUP.md).
Changing this library, or checking someone else's change: the
[verification commands](docs/SETUP.md#verifying-a-change) are the ones CI runs.

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

# Navigate stored context progressively
{:ok, paths} = AgentDb.find("auth", scope: "viking://resources/my_project", limit: 50)
#=> [%{uri: "viking://resources/my_project/auth.md", name: "auth.md", kind: :doc}]
{:ok, lines} = AgentDb.grep("def run", scope: "viking://resources/my_project", limit: 50)
#=> [%{uri: "viking://resources/my_project/src/main.ex", line_number: 2, excerpt: "  def run, do: :ok"}]

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

New here? Follow [Quickstart](docs/QUICKSTART.md) instead — same first success
in 5 minutes with verification. Daily workflows: [Usage](docs/USAGE.md).

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

## Agent Skills

An [Agent Skill](https://code.claude.com/docs/en/skills) is a folder with a
`SKILL.md` at its root and whatever supporting files it needs. Importing one
stores it below `viking://user/{user_id}/skills/{skill_name}`, with every file at
the path it had inside the skill, so an imported skill is an ordinary subtree:

```elixir
my-skills/code-review/
├── SKILL.md
├── references/
│   └── checklist.md
└── scripts/
    └── check.py
```

```elixir
{:ok, content} = AgentDb.read("viking://user/alice/skills/code-review/references/checklist.md")
```

The same import is available from the operations console at `/admin` and from
the command line, and both go through one workflow: what a bundle may look like,
what is refused, and where a skill lands are decided once
(`AgentDb.Skills.Source` and the skills workflow).

### What a source may look like

A source is a **folder**, a **tar archive**, or a **gzip-compressed tar
archive**, and it holds either:

- **one skill** — a folder with a `SKILL.md` at its own root, named after the
  folder, or
- **a collection** — a folder of immediate skill folders, each with a
  `SKILL.md`.

An archive may add **one common wrapper directory** above them, which is what
`tar -czf skills.tar.gz my-skills/` produces; it is recognised automatically.

A skill's files are stored verbatim, including `SKILL.md` itself: its frontmatter
is not parsed, so a skill is preserved exactly as its author wrote it. Files are
read as text, so a file that is not valid UTF-8 is refused rather than mangled.

### From the console

Open `/admin`, fill in the **User ID**, then either

- choose a **Skills folder** — the browser is asked for a whole directory, and
  every file inside it is uploaded with the path it had there, or
- choose a **Skills archive** — one `.tar`, `.tgz` or `.tar.gz` file, recognised
  by its contents rather than its name.

Press **Import skills**. The console reports what happened to every skill
(`imported`, `replaced`, or the reason it failed) and writes nothing at all when
the source is refused, so a bundle that is refused whole leaves the store as it
was.

### From the command line

```bash
mix agent_db.import_skills ./my-skills --user alice
mix agent_db.import_skills ./skills.tar.gz --user alice
```

The task starts the application, imports through the same workflow, prints one
line per skill, and exits with a failure if the source was refused or any skill
failed. `mix help agent_db.import_skills` prints the same rules it follows.

### Data handoff (export_data / import_data)

One agent hands its stored context to another as a single offline tar file:

```elixir
:ok = AgentDb.write("viking://resources/project/readme.md", "# Project")
{:ok, _} = AgentDb.export_data("/tmp/backup.tar.gz")
{:ok, _} = AgentDb.export_data("/tmp/project.tar", scope: "viking://resources/project")
```

```bash
mix agent_db.export_data /tmp/backup.tar.gz --json
mix agent_db.export_data /tmp/project.tar --scope viking://resources/project
mix agent_db.import_data /tmp/backup.tar.gz --json
```

`export_data` snapshots documents (full content plus caller-supplied
abstract/overview), memory provenance, and sessions into a `.tar` or
`.tar.gz` archive with a manifest. `import_data` validates the whole archive
before writing anything — a refused archive (traversal, symlink, non-UTF-8,
oversize, corrupt, newer format) leaves the store exactly as it was — then
merges by URI: missing URIs are created, present ones revised in place,
colliding sessions skipped, nothing outside the archive deleted.
Re-importing an unchanged archive converges without duplication. Embeddings
and generated summaries regenerate through the existing job queue; they are
not carried in the archive.

### Context CLI

```bash
mix agent_db.index --project myapp --dir lib
mix agent_db.search "authentication" --mode keyword --scope viking://resources/myapp
mix agent_db.tree viking://resources/myapp --depth 2
mix agent_db.doctor
```

All four reuse the `AgentDb` facade, so console, WebSocket, and CLI share one
workflow.

### Agent setup (OpenCode, Zed)

`POST /mcp` serves the store as MCP tools for remote agents
(`http://127.0.0.1:6060/mcp` by default, Bearer opt-in). CLI tasks accept
`--json` for machine-readable output. See `docs/agents.md` for copy-paste
OpenCode/Zed snippets, WSL notes, and `tools/install.sh --check`.

### Replacement

A skill whose name is already stored for that user is **replaced whole**: the
stored subtree and the work queued for it are removed, and the source's files are
written in their place. A file the new source does not have does not survive the
replacement, and nothing outside that one skill's subtree is touched.

The replacement of each skill is one atomic step, so a failure leaves the stored
skill exactly as it was; a multi-skill import then reports the skills that landed
and the one that did not, rather than losing the rest to it.

### Limits

One import accepts, and the console's upload is configured to match:

| Limit | Value |
|-------|-------|
| Files and entries in one source | 500 |
| Bytes, compressed input and once expanded | 5,000,000 |
A source that exceeds either is refused before anything is written, and the
error names the limit. Archive members are read in memory and are never
extracted to the filesystem, so a compressed archive cannot expand past the byte
limit.

### What a source is refused for

A reason is always given, and a refused source is never partly written:

- an unsafe path — absolute, containing `..`, a backslash, an empty segment or a
  control character
- a symbolic or hard link, or an entry in an archive that is not a regular file
  or a directory
- the same path twice, or one path stored both as a file and as a directory
- a skill directory with no `SKILL.md`
- a file that is not valid UTF-8 text
- a file count or byte count over the limits above

## Navigating context (find/grep)

`find/2` discovers files and directories by URI path; `grep/2` inspects
matching source lines in full document content (L2). Both are read-only,
need no model, and are available in-process (`AgentDb.find/2`,
`AgentDb.grep/2`) and over WebSocket (`v1.find`, `v1.grep`).

```elixir
{:ok, paths} = AgentDb.find("auth", scope: "viking://resources/project", limit: 50)
{:ok, lines} = AgentDb.grep("TODO", scope: "viking://resources/project", limit: 50)
```

- **Matching:** non-empty literal substring, 1 through 256 characters,
  case-insensitive. `%`, `_`, `\`, and regular-expression metacharacters
  match literally. `find` matches the URI path excluding the `viking://`
  scheme and returns `%{uri, name, kind}` without document content;
  `grep` matches L2 content only (never abstracts or overviews) and
  returns `%{uri, line_number, excerpt}` with one-based line numbers.
- **Scoping:** optional `scope` URI; results include the scope node and
  its descendants only. Scope membership is exact-URI-or-descendant, so
  `viking://resources/project` never matches a sibling
  `viking://resources/project-old`. A malformed scope is
  `{:error, :invalid_uri}`; a missing scope is `{:error, :not_found}`.
- **Limits and ordering:** default `limit` 50, maximum 200;
  `{:error, {:invalid_limit, limit}}` outside 1 through 200.
  `find` is ordered by URI; `grep` by URI then line number. Each `grep`
  excerpt contains the match and is at most 280 characters; an empty
  match is `{:ok, []}`.
- **Storage providers:** custom `AgentDb.Core.Storage` adapters must
  implement `find_paths/3` and `grep_content/3`; startup validates the
  complete port and rejects providers missing them. No migration is
  needed; the operations write nothing.

## Configuration

Full configuration reference (every `AGENT_DB_*` variable with defaults,
listener, auth, backends): [Setup](docs/SETUP.md). The table below is
intentionally not duplicated here so the two cannot disagree.
### HTTP listener

Listener, port, bind interface, and Bearer opt-in: [Setup](docs/SETUP.md#http-listener-and-auth).
Defaults: port `6060`, bind `127.0.0.1` (loopback). `PORT` is **not** read.

### Error responses

Every transport renders a store failure the same way: the status says whether
the caller can fix it, the body carries a machine-readable `code` from one
shared taxonomy, and no detail that might hold a URI, content, or credentials
is echoed.

| Status | When |
|--------|------|
| 400 / 422 | Bad request: `invalid_mode`, `invalid_uri`, `invalid_query`, `invalid_limit`, `not_a_memory_uri`, `is_root`, `missing_argument` |
| 401 | Auth enabled and the Bearer token is missing or wrong |
| 404 | `not_found`, `no_memory` |
| 413 / 429 | `too_large`, `too_many_entries`, `rate_limited` |
| 503 | `model_loading`, `background_jobs_pending` — retry later |
| 500 | Server-side: `inference_failed`, `inference_timeout`, `model_load_failed`, `download_failed`, `background_jobs_failed`, `hybrid_leg_timeout` |

```json
{"error": "invalid_mode", "code": "invalid_mode"}
```

REST carries `error` and `code`; the WebSocket channel carries `reason` and
`code`; MCP carries the message plus `data.reason`. `model_loading` stays the
distinct retry signal on all of them.

`/admin` needs a `secret_key_base` of at least 64 bytes: the browser pipeline
uses a cookie session store, which refuses a shorter secret with a 500 before a
route is reached. `config/config.exs` sets one of that length for development;
a deployment that sets its own must be at least as long.

### Environment Variables

Full table with defaults and failure recovery: [Setup](docs/SETUP.md#environment-reference).
`config/example.exs` is a working starting point: every setting in it has a
default, so it evaluates with no environment set, and an unparseable value is
refused by variable name.

### Choosing an inference provider

One key, `inference_provider`, decides which provider serves `embed/1` and
`summarize/2` and the provider kind `model_status/0` reports:

```elixir
config :agent_db, inference_provider: :ollama
# => Runtime.inference() == AgentDb.Adapters.Inference.Ollama
# => AgentDb.model_status().provider == :ollama
```

A value naming no known provider fails startup validation, rather than serving
local models while the console reports something else.

## WebSocket API

Full event reference with copy-paste payloads: [Usage](docs/USAGE.md#websocket-v1).
Connect to `ws://localhost:6060/api`; with auth enabled, include
`Authorization: Bearer <token>` header on connect.

## Operations

- **Worker count (`job_workers`, `AGENT_DB_JOB_WORKERS`, default CPU cores):**
  the setting is the worker count *per job family* — N embedding plus N
  summarization processes (2N total), each with a unique worker ID. Must be a
  positive integer; startup raises otherwise. More workers drain the queue
  faster but do not increase model throughput: `ModelManager` is a single
  GenServer serializing inference.
- **Write outcomes:** a write persists the document and all required jobs
  atomically. Enqueue failure returns an error with no partial write and
  untouched cache/queue. Sync writes (`async: false`) report one of three
  outcomes: completed (`:ok`), failed (`{:error, {:background_jobs_failed,
  uri}}`), or still outstanding (`{:error, {:background_jobs_pending,
  uri}}`) — never success for failed work.
- **Hybrid search errors:** leg timeouts and task exits return classified
  errors (`{:hybrid_leg_timeout, leg}`, `{:hybrid_leg_failed, leg, _}`)
  without terminating the caller or the WebSocket connection.
- **Telemetry:** `:telemetry` events (`agent_db.operation.stop`,
  `agent_db.job.stop` with queue-wait vs execution split,
  `agent_db.model.stop`) are always emitted locally with bounded dimensions
  (operation/kind/role/outcome) — never URIs, content, prompts, users, or
  credentials.
- **Traces (host-owned export):** the store creates OTel spans and propagates
  W3C context through HTTP/WebSocket operations into durable job payloads
  (additive `_trace` key, no migration; old jobs start a new trace). Spans
  are no-ops until the *host* configures an SDK/exporter/sampler — the store
  ships no exporter and requires none at runtime.
- **Logs:** operational logs are structured fields (component, operation,
  kind, outcome, classified reason, trace/job IDs). Document content, model
  prompts, tokens, and credentials are never logged; configured model URLs
  are redacted (credentials and secret query params removed).
- **Benchmarks:** `mix run bench/agent_db_bench.exs` runs deterministic
  scenarios (reads, tree, keyword/hybrid, writes, queue) on isolated SQLite
  data; baselines live in `bench/baseline.md`. No absolute latency is
  asserted in CI; only repeatable measured deltas justify optimization.

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
| `Qwen3-0.6B` | Summarization | ~0.6B params | GGUF (Q4_K_M) |

Models auto-download on first use to `model_cache_dir`. Can be pre-placed manually.
Details: [Setup](docs/SETUP.md#models-pre-placement-and-cache-recovery).

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
- `ml_backend` (`AGENT_DB_ML_BACKEND`, `auto` | `exla` | `emlx`, default `auto`)
  selects the ML runtime. `:auto` prefers EMLX on Apple Silicon macOS and EXLA
  elsewhere; `:emlx` forces EMLX with fallback to EXLA plus a warning when EMLX
  is unavailable. `AGENT_DB_ML_BACKEND=emlx mix run` forces EMLX;
  `AGENT_DB_ML_BACKEND=exla` pins EXLA for CI/debugging.
- EMLX/EMLXAxon (`{:emlx, "~> 0.5"}`, `{:emlx_axon, "~> 0.5"}`, both
  `optional: true, runtime: false`) are macOS-only acceleration for Apple
  Silicon (MLX GPU/Neural Engine, Metal shaders for LLM). They are not fetched
  on Linux CI and never start unless `ml_backend` needs them; when EMLX init
  fails the store logs a warning and continues on EXLA CPU.
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

MIT — the full text is in [LICENSE](LICENSE).
