# Usage

Daily workflows for the store. Setup lives in `docs/SETUP.md`; the 5-minute
path in `docs/QUICKSTART.md`; editor setup in `docs/agents.md` (canonical for
OpenCode/Zed snippets).

## Documents

URIs look like `viking://resources/my_project/readme.md`,
`viking://user/{id}/memories/…`, `viking://user/{id}/skills/…`, `peers/…`.
Missing URIs return `{:error, :not_found}` or `:not_found` without side effects.

```elixir
:ok = AgentDb.write("viking://resources/my_project/readme.md", "# Hello\n\nBody!")
{:ok, content} = AgentDb.read("viking://resources/my_project/readme.md")
{:ok, children} = AgentDb.list("viking://resources/my_project")
{:ok, tree} = AgentDb.tree("viking://resources/my_project", 2)
:ok = AgentDb.rm("viking://resources/my_project/hello.md")
```

Options for `write/3`: `async:` (override `async_writes`),
`sync_timeout_ms:` (default 30_000), `abstract:` / `overview:` for caller
supplied L0/L1. Writes persist to SQLite before acknowledgement; embeddings
and summaries arrive progressively. Removal clears node store, vector index,
pending jobs, and caches for the subtree.

Layered content: L2 is full content, L0 abstract, L1 overview.

```elixir
:ok = AgentDb.write("viking://resources/my_project/big.md", body, abstract: "One-liner", overview: "Short version")
{:ok, abstract} = AgentDb.abstract("viking://resources/my_project/big.md")
{:ok, overview} = AgentDb.overview("viking://resources/my_project/big.md")
```

Without caller layers the store generates them asynchronously (fallback: first
non-empty line for abstract, first 280 chars for overview).

## Search, find, grep

```elixir
{:ok, results} = AgentDb.search("hello", mode: :keyword)
{:ok, results} = AgentDb.search("greeting", mode: :vector)
{:ok, results} = AgentDb.search("hello", mode: :hybrid)
{:ok, results} = AgentDb.search("hello", mode: :keyword, scope: "viking://resources/my_project", top_k: 10)
```

- Default `mode: :keyword` (no model needed). `:vector` needs embeddings;
  `:hybrid` fuses both with `hybrid_weights: {0.5, 0.5}` (or the identical
  `[keyword: 0.5, vector: 0.5]` list shape).
- `scope:` limits to a subtree (exact URI or descendants only).
- `top_k:` caps results. Default 10, maximum 200; an out-of-range value
  returns `{:error, {:invalid_limit, value}}` rather than silently answering a
  different question than the one asked. This is a breaking change for a
  caller that relied on an unbounded keyword result set.
- Model still loading → `{:error, :model_loading}`; retry later.

`find/2` matches URI paths; `grep/2` matches L2 content lines. Both are
literal, case-insensitive, no model needed:

```elixir
{:ok, paths} = AgentDb.find("auth", scope: "viking://resources/my_project", limit: 50)
#=> [%{uri: "viking://resources/my_project/auth.md", name: "auth.md", kind: :doc}]

{:ok, lines} = AgentDb.grep("def run", scope: "viking://resources/my_project", limit: 50)
#=> [%{uri: "viking://resources/my_project/src/main.ex", line_number: 2, excerpt: "  def run, do: :ok"}]
```

Query 1–256 chars, non-empty; `limit` default 50, max 200
(`{:error, {:invalid_limit, limit}}` outside 1–200). `find` orders by URI;
`grep` by URI then line number, excerpts ≤ 280 chars. `grep` never looks at
abstracts or overviews. Empty match → `{:ok, []}`.

## Memory

Typed durable facts under `viking://user/memories/<type>/<name>`. Types:
`profile`, `preferences`, `entities`, `events`, `experiences`. The URI is the
identity: writing the same URI revises (old value superseded, still
inspectable); a different URI adds. No model participates — fully
deterministic.

```elixir
{:ok, uri} = AgentDb.remember("viking://user/memories/preferences/language", "prefers Elixir",
  confidence: 0.9, source: session_id)
{:ok, memories} = AgentDb.recall(type: :preferences)
{:ok, [memory]} = AgentDb.recall("viking://user/memories/preferences/language")
{:ok, history} = AgentDb.recall(uri: "viking://user/memories/preferences/language", include_superseded: true)
:ok = AgentDb.forget("viking://user/memories/preferences/language")
```

- `confidence:` 0.0–1.0, default `0.5` (`AgentDb.default_confidence/0`);
  `importance:` 0.0–1.0, default `0.5`. `candidate: true` records awaiting
  promotion (also forced by near-zero confidence or duplicate values);
  `promote_memory/1` activates, `reject_memory_candidate/1` removes without a
  trace, `pending_memory_candidates/0` lists the review queue.
- `recall()` with no args returns everything active; `type:` / `term:` /
  subtree URI filter; without a term results order by descending confidence,
  with a term by confidence + semantic similarity (exact matches boosted,
  stale memories penalized); no match → `{:ok, []}`. Every recall records
  surfacing on the rows it returns.
- `memory_conflicts/0` reports similar active memories at distinct URIs
  read-only (no inference of its own); `{:error, :embeddings_unavailable}`
  when there is nothing stored to compare.
- `forget/1` on a missing memory → `{:error, :no_memory}`; it removes value
  plus provenance including superseded assertions. A plain document at the URI
  is left alone.
- Memories embed for semantic search but never generate summaries.

## Sessions

```elixir
{:ok, session_id} = AgentDb.create_session()
:ok = AgentDb.append_message(session_id, :user, "Remember this")
:ok = AgentDb.append_message(session_id, :assistant, "Got it")
{:ok, messages} = AgentDb.get_session(session_id)
{:ok, uri} = AgentDb.commit_session(session_id, "viking://user/me/memories/session-1")
```

Roles: `:user` | `:assistant` | `:system`. Commit is idempotent per
(session, destination): unchanged re-commit → `{:ok, :unchanged}`; if the
destination was removed, re-commit restores it.

## Skills

A skill is a folder with `SKILL.md` at its root. Import stores it under
`viking://user/{id}/skills/{skill_name}` verbatim (frontmatter not parsed;
non-UTF-8 refused). Source may be one skill or a collection; archives may add
one wrapper dir. Limits: 500 files/entries, 5_000_000 bytes expanded — over
either is refused before anything is written.

```elixir
{:ok, out} = AgentDb.import_skills("alice", {:path, "./my-skills"})
{:ok, out} = AgentDb.import_skills("alice", {:path, "./skills.tar.gz"})
{:ok, content} = AgentDb.read("viking://user/alice/skills/code-review/references/checklist.md")
```

A same-named skill is replaced whole atomically; failure leaves the stored
skill untouched. Console (`/admin`) and CLI go through the same workflow:

```bash
mix agent_db.import_skills ./my-skills --user alice
mix agent_db.import_skills ./skills.tar.gz --user alice
```

Refused for: unsafe paths (`..`, absolute, backslash, empty segments,
controls), symlinks / non-regular archive entries, duplicate paths, skill dir
without `SKILL.md`, non-UTF-8 files, over limits. `mix help
agent_db.import_skills` prints the same rules.

## Data handoff (export / import)

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

Export snapshots documents (content plus caller-supplied abstract/overview),
memory provenance, and sessions. Import validates the whole archive first
(traversal, symlink, non-UTF-8, oversize, corrupt, newer format leave the
store untouched), then merges by URI: missing created, present revised,
colliding sessions skipped, nothing outside deleted. Re-import converges
without duplication. Embeddings and generated summaries regenerate via the job
queue — they are not carried in the archive.

## CLI (`mix agent_db.*`)

Every task supports `--json` (JSON on stdout, reason on stderr, non-zero exit
on failure); without it, human-readable text is unchanged.

```bash
mix agent_db.read "viking://resources/myapp/readme.md" --json
mix agent_db.search "authentication" --mode hybrid --json
mix agent_db.search "authentication" --mode keyword --scope viking://resources/myapp --top-k 10 --json
mix agent_db.find "auth" --scope viking://resources/myapp --limit 50 --json
mix agent_db.grep "def run" --scope viking://resources/myapp --limit 50 --json
mix agent_db.recall --type preferences --json
mix agent_db.tree viking://resources/myapp --depth 2 --json
mix agent_db.index --project myapp --dir lib
mix agent_db.doctor --json
```

Task list: `read`, `search`, `find`, `grep`, `recall`, `tree`, `index`,
`import_skills`, `import_data`, `export_data`, `doctor`. Run
`mix help agent_db.<task>` for exact flags (`--mode`, `--scope`, `--top-k` /
`--limit`, `--depth`, `--type`, `--term`, `--include-superseded`,
`--project`, `--dir`, `--user`).

## MCP (OpenCode, Zed)

One shared daemon serves `POST /mcp` (default
`http://127.0.0.1:6060/mcp`, port from `AGENT_DB_HTTP_PORT`). Canonical
snippets and WSL notes live in `docs/agents.md` — copy from there, not from
below:

```jsonc
// opencode.jsonc (no auth)
{ "mcp": { "servers": { "agent-db": { "type": "remote", "url": "http://127.0.0.1:6060/mcp" } } } }
```

| MCP tool | Facade |
|----------|--------|
| `context_read`, `context_write`, `context_rm` | `read`, `write`, `rm` |
| `context_list`, `context_tree` | `list`, `tree` |
| `context_search`, `context_find`, `context_grep` | `search`, `find`, `grep` |
| `memory_recall`, `memory_remember`, `memory_forget` | `recall`, `remember`, `forget` |
| `session_create`, `session_append`, `session_get`, `session_commit` | sessions |
| `store_health` | `health_check` + `model_status` + `queue_stats` |

Errors are JSON (`{"code": …, "message": …}`). `model_loading` means retry
later; anything else names the cause. The session stays usable after an error.
Option names match the facade (`mode`, `scope`, `top_k`, `limit`,
`confidence`, `source`). `tools/install.sh --check` prints these snippets and
verifies `tools/list` answers with `context_read`.

## WebSocket (`v1.*`)

Connect to `ws://localhost:6060/api` (Bearer header when auth is on). Events
mirror the facade:

```json
{"event": "v1.write", "payload": {"uri": "viking://resources/foo.md", "content": "Hello", "opts": {}}}
{"event": "v1.read", "payload": {"uri": "viking://resources/foo.md"}}
{"event": "v1.search", "payload": {"term": "hello", "opts": {"mode": "hybrid", "top_k": 10}}}
{"event": "v1.find", "payload": {"term": "auth", "opts": {"scope": "viking://resources/project", "limit": 50}}}
{"event": "v1.grep", "payload": {"term": "def run", "opts": {"scope": "viking://resources/project", "limit": 50}}}
{"event": "v1.create_session", "payload": {}}
{"event": "v1.append_message", "payload": {"session_id": "...", "role": "user", "content": "hi"}}
{"event": "v1.get_session", "payload": {"session_id": "..."}}
{"event": "v1.commit_session", "payload": {"session_id": "...", "destination_uri": "viking://user/me/memories/s"}}
{"event": "v1.model_status", "payload": {}}
{"event": "v1.subscribe", "payload": {"uri": "viking://resources/project"}}
{"event": "v1.unsubscribe", "payload": {"uri": "viking://resources/project"}}
{"event": "v1.search_progress", "payload": {"term": "hello", "opts": {"mode": "keyword"}}}
```

Subscriptions push versioned `{:context_changed, uri, kind, version}` over
`AgentDb.PubSub` (`AgentDb.subscribe/1` in-process); BEAM distribution is
explicitly deferred. `traceparent` may ride top-level or inside `opts`
(WebSocket) or as an HTTP header; missing or malformed context starts a new
trace without affecting results.

## Console and trust boundary

Open `/admin` to import skills (User ID + folder or `.tar`/`.tgz`/`.tar.gz`);
it reports per-skill `imported` / `replaced` / failure reason and writes
nothing when the source is refused.

The same page is the operations console. It reports:

| Section | What it answers |
| --- | --- |
| Storage | Database and WAL byte sizes; document and directory counts overall and per top-level subtree |
| Cache | Entry counts and memory per ETS cache table |
| Runtime | Node uptime, supervisor and process counts, BEAM memory |
| Models | Per role: load state, last load duration, last latency, in-flight count, model identity, provider and remote provider health |
| Queue | Per-status counts, age of the oldest pending job, failed jobs with kind, URI, attempts, and classified reason |
| Index | Indexed vector rows and the number of documents the index describes |
| Recent errors | Bounded, newest-first, classified reason and operation only |

Every value is read-only and bounded. An unreachable remote provider is shown
as unreachable, not as loaded, and a cache that has grown reads differently
from a store whose content has.

Default no-auth daemon binds loopback only: any local process can read *and
write*. That fits one laptop shared by two editors and nothing else. To serve
beyond loopback, set `AGENT_DB_HTTP_IP`, enable Bearer auth, and keep the port
off wider networks than intended. See `docs/SETUP.md` and `docs/agents.md`
§7.

## Status and observability

```elixir
AgentDb.health_check()
#=> %{status: ..., checks: %{db: true, models: true}}
AgentDb.model_status()
AgentDb.queue_stats()
```

`mix agent_db.doctor` reports the same plus PubSub and inference provider.
Telemetry (`agent_db.operation.stop`, `agent_db.job.stop`, `agent_db.model.stop`)
and structured logs never carry URIs, content, prompts, users, or
credentials. Benchmarks: `mix run bench/agent_db_bench.exs` (baselines in
`bench/baseline.md`).
