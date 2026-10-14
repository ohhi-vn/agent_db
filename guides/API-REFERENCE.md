# API Reference

Complete reference for AgentDb's four public interfaces: the Elixir `AgentDb`
module, the `mix agent_db.*` CLI, MCP tools over Streamable HTTP, and WebSocket
`v1.*` events. Each section is written against its source of truth so it can
be checked, not taken on faith:

| Interface | Source of truth |
|-----------|-----------------|
| Elixir API | `lib/agent_db/agent_db.ex` — rendered at [hexdocs.pm/agent_db](https://hexdocs.pm/agent_db/AgentDb.html) |
| CLI | `lib/mix/tasks/` — each task's `@switches` |
| MCP | `AgentDbWeb.Mcp.tools/0` in `lib/agent_db_web/mcp.ex` |
| WebSocket | `handle_in` clauses in `lib/agent_db_web/channel.ex` |

The generated documentation is the API reference for the Elixir module — this
guide maps entry points to it instead of copying signatures, which would go
stale the moment the code moves. Generate it locally with `mix docs`.

## 1. Elixir API (`AgentDb` module)

Start the application once, then every call below is available:
`{:ok, _} = Application.ensure_all_started(:agent_db)`. Links go to the
versioned generated docs; local `mix docs` output matches them.

### Tree operations

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.write/3`](https://hexdocs.pm/agent_db/AgentDb.html#write/3) | Writes a document, creating missing parents; acknowledges before embedding/summarization | [link](https://hexdocs.pm/agent_db/AgentDb.html#write/3) |
| [`AgentDb.read/1`](https://hexdocs.pm/agent_db/AgentDb.html#read/1) | Reads L2 content, falling back through generated layers | [link](https://hexdocs.pm/agent_db/AgentDb.html#read/1) |
| [`AgentDb.abstract/1`](https://hexdocs.pm/agent_db/AgentDb.html#abstract/1) | Reads the L0 abstract layer | [link](https://hexdocs.pm/agent_db/AgentDb.html#abstract/1) |
| [`AgentDb.overview/1`](https://hexdocs.pm/agent_db/AgentDb.html#overview/1) | Reads the L1 overview layer | [link](https://hexdocs.pm/agent_db/AgentDb.html#overview/1) |
| [`AgentDb.stored_layers/1`](https://hexdocs.pm/agent_db/AgentDb.html#stored_layers/1) | Which layers exist for a URI | [link](https://hexdocs.pm/agent_db/AgentDb.html#stored_layers/1) |
| [`AgentDb.layers/1`](https://hexdocs.pm/agent_db/AgentDb.html#layers/1) | Reads all three layers (L0, L1, L2) in one call, each with source and character count | [link](https://hexdocs.pm/agent_db/AgentDb.html#layers/1) |
| [`AgentDb.list/1`](https://hexdocs.pm/agent_db/AgentDb.html#list/1) | Direct children of a URI | [link](https://hexdocs.pm/agent_db/AgentDb.html#list/1) |
| [`AgentDb.tree/2`](https://hexdocs.pm/agent_db/AgentDb.html#tree/2) | Depth-limited tree projection | [link](https://hexdocs.pm/agent_db/AgentDb.html#tree/2) |
| [`AgentDb.rm/1`](https://hexdocs.pm/agent_db/AgentDb.html#rm/1) | Removes the subtree at a URI | [link](https://hexdocs.pm/agent_db/AgentDb.html#rm/1) |
| [`AgentDb.find/2`](https://hexdocs.pm/agent_db/AgentDb.html#find/2) | Literal URI-path discovery with `scope:` | [link](https://hexdocs.pm/agent_db/AgentDb.html#find/2) |
| [`AgentDb.grep/2`](https://hexdocs.pm/agent_db/AgentDb.html#grep/2) | Literal L2 line matches with excerpts | [link](https://hexdocs.pm/agent_db/AgentDb.html#grep/2) |
| [`AgentDb.list_all_documents/2`](https://hexdocs.pm/agent_db/AgentDb.html#list_all_documents/2) | Paged listing of the whole tree | [link](https://hexdocs.pm/agent_db/AgentDb.html#list_all_documents/2) |

### Search

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.search/2`](https://hexdocs.pm/agent_db/AgentDb.html#search/2) | Keyword, vector, or hybrid search; `mode:`, `scope:`, `top_k:`, `hybrid_weights:`, `fields:` options | [link](https://hexdocs.pm/agent_db/AgentDb.html#search/2) |

`fields:` selects which per-result fields are returned: `:uri` (always
required — a result without its URI cannot be fetched), `:content`,
`:abstract`, `:overview`, `:score`. Omitted returns all of them, so an
existing caller sees the same result set as before. An unknown name, an empty
list, or a selection without `:uri` is `{:error, {:invalid_fields, value}}`
rather than a substituted answer, and the projection reaches the statement
that reads the rows — a caller selecting `:abstract` does not pay to read
document content it cannot receive.

```elixir
# URIs and abstracts only, for deciding which documents to read
{:ok, results} = AgentDb.search("vector index", mode: :hybrid, fields: [:uri, :abstract, :score])
```

### Memory

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.remember/3`](https://hexdocs.pm/agent_db/AgentDb.html#remember/3) | Stores a durable fact with `confidence:`, `importance:`, `candidate:`, `source:` | [link](https://hexdocs.pm/agent_db/AgentDb.html#remember/3) |
| [`AgentDb.recall/1`](https://hexdocs.pm/agent_db/AgentDb.html#recall/1) | Decay-aware recall with `include_superseded:` | [link](https://hexdocs.pm/agent_db/AgentDb.html#recall/1) |
| [`AgentDb.forget/1`](https://hexdocs.pm/agent_db/AgentDb.html#forget/1) | Removes a memory | [link](https://hexdocs.pm/agent_db/AgentDb.html#forget/1) |
| [`AgentDb.promote_memory/1`](https://hexdocs.pm/agent_db/AgentDb.html#promote_memory/1) | Promotes a candidate to durable | [link](https://hexdocs.pm/agent_db/AgentDb.html#promote_memory/1) |
| [`AgentDb.reject_memory_candidate/1`](https://hexdocs.pm/agent_db/AgentDb.html#reject_memory_candidate/1) | Rejects a candidate | [link](https://hexdocs.pm/agent_db/AgentDb.html#reject_memory_candidate/1) |
| [`AgentDb.pending_memory_candidates/1`](https://hexdocs.pm/agent_db/AgentDb.html#pending_memory_candidates/1) | Candidates awaiting promotion | [link](https://hexdocs.pm/agent_db/AgentDb.html#pending_memory_candidates/1) |
| [`AgentDb.memory_conflicts/1`](https://hexdocs.pm/agent_db/AgentDb.html#memory_conflicts/1) | Read-only conflict surfacing | [link](https://hexdocs.pm/agent_db/AgentDb.html#memory_conflicts/1) |
| [`AgentDb.memory_types/0`](https://hexdocs.pm/agent_db/AgentDb.html#memory_types/0) | The valid memory types | [link](https://hexdocs.pm/agent_db/AgentDb.html#memory_types/0) |
| [`AgentDb.default_confidence/0`](https://hexdocs.pm/agent_db/AgentDb.html#default_confidence/0) | Default confidence for new memories | [link](https://hexdocs.pm/agent_db/AgentDb.html#default_confidence/0) |

### Sessions

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.create_session/0`](https://hexdocs.pm/agent_db/AgentDb.html#create_session/0) | Creates an append-only session | [link](https://hexdocs.pm/agent_db/AgentDb.html#create_session/0) |
| [`AgentDb.append_message/3`](https://hexdocs.pm/agent_db/AgentDb.html#append_message/3) | Appends a message | [link](https://hexdocs.pm/agent_db/AgentDb.html#append_message/3) |
| [`AgentDb.get_session/1`](https://hexdocs.pm/agent_db/AgentDb.html#get_session/1) | Reads every message, in order | [link](https://hexdocs.pm/agent_db/AgentDb.html#get_session/1) |
| [`AgentDb.commit_session/3`](https://hexdocs.pm/agent_db/AgentDb.html#commit_session/3) | Commits a session into the tree | [link](https://hexdocs.pm/agent_db/AgentDb.html#commit_session/3) |

### Agent Skills

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.import_skills/2`](https://hexdocs.pm/agent_db/AgentDb.html#import_skills/2) | Imports a skill folder or tar archive | [link](https://hexdocs.pm/agent_db/AgentDb.html#import_skills/2) |
| [`AgentDb.list_skills/1`](https://hexdocs.pm/agent_db/AgentDb.html#list_skills/1) | Lists imported skills | [link](https://hexdocs.pm/agent_db/AgentDb.html#list_skills/1) |
| [`AgentDb.set_enabled/2`](https://hexdocs.pm/agent_db/AgentDb.html#set_enabled/2) | Enables/disables one skill | [link](https://hexdocs.pm/agent_db/AgentDb.html#set_enabled/2) |
| [`AgentDb.set_group/2`](https://hexdocs.pm/agent_db/AgentDb.html#set_group/2) | Sets one skill's group | [link](https://hexdocs.pm/agent_db/AgentDb.html#set_group/2) |
| [`AgentDb.bulk_set_enabled/2`](https://hexdocs.pm/agent_db/AgentDb.html#bulk_set_enabled/2) | Bulk enable/disable | [link](https://hexdocs.pm/agent_db/AgentDb.html#bulk_set_enabled/2) |
| [`AgentDb.bulk_set_group/2`](https://hexdocs.pm/agent_db/AgentDb.html#bulk_set_group/2) | Bulk group assignment | [link](https://hexdocs.pm/agent_db/AgentDb.html#bulk_set_group/2) |
| [`AgentDb.skill_import_limits/0`](https://hexdocs.pm/agent_db/AgentDb.html#skill_import_limits/0) | Bounded import limits | [link](https://hexdocs.pm/agent_db/AgentDb.html#skill_import_limits/0) |
| [`AgentDb.skill_import_error_message/1`](https://hexdocs.pm/agent_db/AgentDb.html#skill_import_error_message/1) | Human message for an import refusal | [link](https://hexdocs.pm/agent_db/AgentDb.html#skill_import_error_message/1) |

### Data portability

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.export_data/2`](https://hexdocs.pm/agent_db/AgentDb.html#export_data/2) | Exports store data to a tar archive | [link](https://hexdocs.pm/agent_db/AgentDb.html#export_data/2) |
| [`AgentDb.import_data/2`](https://hexdocs.pm/agent_db/AgentDb.html#import_data/2) | Imports an exported archive | [link](https://hexdocs.pm/agent_db/AgentDb.html#import_data/2) |
| [`AgentDb.data_transfer_limits/0`](https://hexdocs.pm/agent_db/AgentDb.html#data_transfer_limits/0) | Bounded transfer limits | [link](https://hexdocs.pm/agent_db/AgentDb.html#data_transfer_limits/0) |
| [`AgentDb.export_data_error_message/1`](https://hexdocs.pm/agent_db/AgentDb.html#export_data_error_message/1) | Human message for a transfer failure | [link](https://hexdocs.pm/agent_db/AgentDb.html#export_data_error_message/1) |

### Vector index

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.index_coverage/0`](https://hexdocs.pm/agent_db/AgentDb.html#index_coverage/0) | Embedding coverage of the tree | [link](https://hexdocs.pm/agent_db/AgentDb.html#index_coverage/0) |
| [`AgentDb.backfill_vector_index/0`](https://hexdocs.pm/agent_db/AgentDb.html#backfill_vector_index/0) | Re-embeds stale rows in the background | [link](https://hexdocs.pm/agent_db/AgentDb.html#backfill_vector_index/0) |
| [`AgentDb.prune_vector_index/1`](https://hexdocs.pm/agent_db/AgentDb.html#prune_vector_index/1) | Drops stale vector rows | [link](https://hexdocs.pm/agent_db/AgentDb.html#prune_vector_index/1) |

### Status, observability, and subscriptions

| Entry point | What it does | Docs |
|-------------|--------------|------|
| [`AgentDb.health_check/0`](https://hexdocs.pm/agent_db/AgentDb.html#health_check/0) | Aggregate readiness for orchestration probes | [link](https://hexdocs.pm/agent_db/AgentDb.html#health_check/0) |
| [`AgentDb.model_status/0`](https://hexdocs.pm/agent_db/AgentDb.html#model_status/0) | Per-role model state, latency, provider health | [link](https://hexdocs.pm/agent_db/AgentDb.html#model_status/0) |
| [`AgentDb.queue_stats/0`](https://hexdocs.pm/agent_db/AgentDb.html#queue_stats/0) | Queue depth by state | [link](https://hexdocs.pm/agent_db/AgentDb.html#queue_stats/0) |
| [`AgentDb.queue_detail/1`](https://hexdocs.pm/agent_db/AgentDb.html#queue_detail/1) | Oldest pending age + failed jobs with classified reasons | [link](https://hexdocs.pm/agent_db/AgentDb.html#queue_detail/1) |
| [`AgentDb.operation_stats/0`](https://hexdocs.pm/agent_db/AgentDb.html#operation_stats/0) | Operation counters by outcome | [link](https://hexdocs.pm/agent_db/AgentDb.html#operation_stats/0) |
| [`AgentDb.cache_stats/0`](https://hexdocs.pm/agent_db/AgentDb.html#cache_stats/0) | Cache sizes | [link](https://hexdocs.pm/agent_db/AgentDb.html#cache_stats/0) |
| [`AgentDb.storage_stats/0`](https://hexdocs.pm/agent_db/AgentDb.html#storage_stats/0) | Storage footprint and tree composition | [link](https://hexdocs.pm/agent_db/AgentDb.html#storage_stats/0) |
| [`AgentDb.recent_errors/1`](https://hexdocs.pm/agent_db/AgentDb.html#recent_errors/1) | Bounded recent operational errors | [link](https://hexdocs.pm/agent_db/AgentDb.html#recent_errors/1) |
| [`AgentDb.runtime_snapshot/0`](https://hexdocs.pm/agent_db/AgentDb.html#runtime_snapshot/0) | Read-only BEAM runtime snapshot (bounded, redacted) | [link](https://hexdocs.pm/agent_db/AgentDb.html#runtime_snapshot/0) |
| [`AgentDb.subscribe/1`](https://hexdocs.pm/agent_db/AgentDb.html#subscribe/1) | Subscribes a process to `{:context_changed, uri, kind, version}` | [link](https://hexdocs.pm/agent_db/AgentDb.html#subscribe/1) |
| [`AgentDb.unsubscribe/1`](https://hexdocs.pm/agent_db/AgentDb.html#unsubscribe/1) | Unsubscribes | [link](https://hexdocs.pm/agent_db/AgentDb.html#unsubscribe/1) |

Full signatures, option types with defaults, and every success/error return
shape live in the generated docs (hexdocs link per row, or `mix docs`).

## 2. CLI (`mix agent_db.*`)

Every task takes `--json` (machine-readable stdout) and `--no-compile`
(skips the app start). Without `--json`, output is human text. Failures write
to stderr and exit non-zero; exit code 0 means success.

| Task | Purpose | Switches |
|------|---------|----------|
| `mix agent_db.read` | Reads a document's full content (L2) | `--json`, `--no-compile` |
| `mix agent_db.abstract` | Reads a document's L0 abstract only | `--json`, `--no-compile` |
| `mix agent_db.overview` | Reads a document's L1 overview only | `--json`, `--no-compile` |
| `mix agent_db.search` | Searches the context tree | `--mode`, `--scope`, `--top-k`, `--json`, `--no-compile` |
| `mix agent_db.find` | Discovers paths by literal substring | `--scope`, `--limit`, `--json`, `--no-compile` |
| `mix agent_db.grep` | Searches document content by literal substring | `--scope`, `--limit`, `--json`, `--no-compile` |
| `mix agent_db.tree` | Shows the context tree | `--depth`, `--json`, `--no-compile` |
| `mix agent_db.recall` | Reads memories back | `--type`, `--term`, `--include-superseded`, `--json`, `--no-compile` |
| `mix agent_db.index` | Indexes Elixir sources into the context tree | `--project`, `--dir`, `--json`, `--no-compile` |
| `mix agent_db.import_skills` | Imports Agent Skills from a folder or a tar archive | `--user`, `--json`, `--no-compile` |
| `mix agent_db.export_data` | Exports store data to a tar archive | `--scope`, `--json`, `--no-compile` |
| `mix agent_db.import_data` | Imports store data from a tar archive | `--json`, `--no-compile` |
| `mix agent_db.doctor` | Checks store health and configuration | `--json`, `--no-compile` |
| `mix agent_db.seed` | Seeds a deterministic demo dataset (dev/test only) | `--prefix`, `--force`, `--clean`, `--allow-prod`, `--json`, `--no-compile` |

## 3. MCP tools (Streamable HTTP at `POST /mcp`)

The tool set is `AgentDbWeb.Mcp.tools/0` — 19 tools. Requests are JSON-RPC
2.0 (`tools/call` with `{"name": ..., "arguments": {...}}`).

| Tool | Request arguments (required in **bold**) | Description |
|------|-------------------------------------------|-------------|
| `context_read` | **uri** | Reads a document's full content (L2) |
| `context_abstract` | **uri** | Reads a document's L0 abstract only |
| `context_overview` | **uri** | Reads a document's L1 overview only |
| `context_layers` | **uri** | Reads L0, L1, and L2 together, each with its text, source (`stored` or `fallback`), and character count |
| `context_write` | **uri**, **content** | Writes a document, creating missing parents |
| `context_rm` | **uri** | Removes the subtree at a URI |
| `context_list` | **uri** | Lists the direct children of a URI |
| `context_tree` | **uri**, depth | Depth-limited projection of the tree |
| `context_search` | **term**, mode, scope, top_k, fields | Searches by keyword, vector, or hybrid; `fields` selects which per-result fields to return |
| `context_find` | **term**, scope, limit | Discovers paths by literal substring |
| `context_grep` | **term**, scope, limit | Inspects L2 content lines by literal substring |
| `memory_recall` | uri, type, term, include_superseded | Reads memories back by URI, type, or term |
| `memory_remember` | **uri**, **value**, confidence, source | Records a durable fact as a memory |
| `memory_forget` | **uri** | Removes a memory and its provenance |
| `session_create` | — | Creates a session and returns its id |
| `session_append` | **session_id**, **role**, **content** | Appends a message to a session |
| `session_get` | **session_id** | Returns every message of a session, in order |
| `session_commit` | **session_id**, **destination_uri** | Commits a session into the tree at a URI |
| `store_health` | — | Store health, model status, and queue depth |

**Success response** — a JSON-RPC result whose content is the data as JSON:

```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"content\":\"...\"}"}]}}
```

**Error response** — a JSON-RPC error; the bounded `code` rides in
`data.reason`. A model that is still loading is signalled distinctly as
`-32001`; every other failure is `-32000` with the classified code:

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"...","data":{"reason":"model_loading"}}}
```

Confirm the live tool list with `tools/list` (what `tools/install.sh --check`
asserts against `context_read`). With Bearer auth enabled, send the token as
`Authorization: Bearer <token>`.

## 4. WebSocket events (Phoenix Channel `/api`)

Events are `{"event": "v1.*", "payload": {...}}`. The reply is
`{:ok, <payload>}` on success and
`{:error, %{reason: <message>, code: <classified code>}}` on failure. `:ok`-only
operations reply `{:ok, %{status: "ok"}}`.

| Event | Payload | Reply payload |
|-------|---------|---------------|
| `v1.write` | **uri**, **content** (+ `opts`: `async`, `abstract`, `overview`) | write result |
| `v1.read` | **uri** | `content` |
| `v1.abstract` | **uri** | `abstract` |
| `v1.overview` | **uri** | `overview` |
| `v1.list` | **uri** | `names` |
| `v1.tree` | **uri**, `depth` (default 2) | `tree` |
| `v1.rm` | **uri** | `:ok` |
| `v1.search` | **term** + `mode`/`scope`/`top_k`/`hybrid_weights` in `opts` | `results` |
| `v1.find` | **term**, `scope`, `limit` | results |
| `v1.grep` | **term**, `scope`, `limit` | results |
| `v1.remember` | **uri**, **value** (+ `confidence`, `importance`, `type`, `source`) | memory result |
| `v1.recall` | `uri`/`type`/`term` (+ `include_superseded`) | memories |
| `v1.forget` | **uri** | `:ok` |
| `v1.create_session` | — | `session_id` |
| `v1.get_session` | **session_id** | messages |
| `v1.subscribe` | **uri** | `:ok` |
| `v1.unsubscribe` | **uri** | `:ok` |
| `v1.search_progress` | **term** (as `v1.search`) | `results` + progress events |
| `v1.model_status` | — | model status |
| `v1.health` | — | health check |

**Pushed events** (server-to-client only): `v1.append_message` and
`v1.commit_session` are responses to their matching operations, and
`v1.context_changed` (`{uri, kind, version}`) is the subscription push.

**Subscriptions** are per-connection and do not survive a reconnect —
re-subscribe after every reconnect.

**Trace correlation**: a `traceparent` is accepted as an HTTP header, at the
payload's top level, or inside `opts` (W3C format).

## 5. Error code catalog

One bounded taxonomy classifies every failure on every transport. The source
is `AgentDb.Observability` (`classify_reason/1`, the caller-error tags, and
the `http_status/1` mapping); each code also appears as the log `reason` and
in transport error payloads.

| Category | Codes | HTTP |
|----------|-------|------|
| Missing | `not_found`, `no_memory`, `assertion_not_found` | 404 |
| Authorization | `unauthorized` | 401 |
| Retryable unavailability | `model_loading`, `background_jobs_pending`, `vector_index_unavailable`, `storage_busy` | 503 |
| Size limits | `too_large`, `too_big`, `too_many_entries` | 413 |
| Rate limiting | `rate_limited` | 429 |
| Caller errors | `invalid_mode`, `invalid_uri`, `invalid_query`, `invalid_limit`, `invalid_document`, `invalid_memory`, `invalid_memory_type`, `invalid_session`, `invalid_user_id`, `invalid_scope`, `invalid_json`, `invalid_argument`, `invalid_payload`, `invalid_group`, `not_a_memory_uri`, `is_root`, `missing_argument`, `unknown_event`, `unknown_tool`, `unsafe_path`, `unsupported_entry`, `unexpected_entry`, `empty` | 422 |
| Model and inference | `model_not_found`, `model_load_failed`, `download_failed`, `inference_failed`, `inference_timeout`, `hybrid_leg_timeout`, `hybrid_leg_failed`, `embeddings_unavailable`, `no_provider_url`, `background_jobs_failed` | 500 |
| Fallback | `error` (anything unrecognised) | 500 |

Any tagged reason (`{tag, detail}`) classifies to its tag, so the set grows
only by reusing or extending these codes — never free-form text.

**Where the code appears per transport**: Elixir — classify with
`Observability.error_code(reason)`; CLI — stderr message; MCP —
`error.data.reason` (with `-32001` for `model_loading`); WebSocket —
`error.code` in the reply payload.

For the operational side (alerting, log interpretation, symptom-driven
diagnosis) see [MONITORING.md](MONITORING.md) and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).
