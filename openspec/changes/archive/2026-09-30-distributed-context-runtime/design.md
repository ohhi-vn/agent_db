# Design

## Context

See proposal.md Why. Current state shaping the approach:

- `AgentDb.Application` builds `Phoenix.PubSub (AgentDb.PubSub)` → `Cache` → `Runtime.storage().child_specs` (SQLite default) → `Runtime.inference().child_specs` (local EXLA/EMLX) → worker pools → transport (Phoenix Channel `v1.*`). `Runtime.validate!/0` fails fast on incomplete providers.
- Invariants that must hold: SQLite-as-source-of-truth, no cache-ahead-of-disk, removal completeness across every URI-keyed store, durable JobQueue with defer-vs-fail distinction, `:model_loading` distinct from failure, bounded telemetry dimensions with no content/credentials, W3C propagation without changing payload shapes.
- `AgentDb.PubSub` is started but unused beyond endpoint config — subscriptions are greenfield with no existing broadcast to migrate.
- `Core.Storage` already owns whole operations (`put_document`, `remove_subtree`, `replace_skill`); `Core.Inference` already splits `embed/1` vs `summarize/2`. Provider work belongs behind those ports, not as parallel systems.
- Channel `answer/2` already distinguishes `:model_loading` from failures; `Observability.extract_context/1` already carries W3C through HTTP/WS.

## Goals / Non-Goals

**Goals:**
- Add local-first reactive subscriptions, structural Elixir indexing, version-aware Hex docs, read-only BEAM snapshots, and pluggable inference without breaking existing `read/write/search/find/grep` contracts.
- Keep default install fully local (`{:agent_db, "~> 0.1"}` + SQLite/ETS/Mnesia, no Docker/keys) with remote adapters opt-in.

**Non-Goals:**
- BEAM cluster distribution (libcluster, Horde/:pg global search, CRDTs, agent-to-agent sharing) — deferred; this change adds only versioned events and provider ports that enable it.
- Postgres/pgvector/ClickHouse/Scylla adapter implementations — only port documentation and validation path.
- Reranker/intent-model training, VLM support, IDE plugins.

## Decisions

### 1. Subscriptions broadcast after commit in application workflows, not in storage
Broadcast `{:context_changed, uri, kind, version}` over `AgentDb.PubSub` from `Documents/Memories/Skills/Sessions` workflows after the storage call succeeds. Version is the node's monotonic row version (fallback: wall-clock + counter per URI).
- Alternative considered: broadcast inside SQLite adapter transaction — rejected, would couple every future storage adapter to PubSub and risk emitting before commit.
- Topic: `context:<uri>` hierarchy with subscriber-side prefix match (exact-URI-or-descendant) to avoid topic explosion; unsubscribed/exited processes simply stop receiving.

### 2. Inference providers implement `Core.Inference` behind `Runtime`
New `AgentDb.Adapters.Inference.Local` (extracted current Bumblebee/EXLA/EMLX logic) stays default; `AgentDb.Adapters.Inference.Ollama` and `OpenAICompatible` use existing `Req` dep with bounded timeouts mapping to `{:error, {:inference_timeout, _}}` vs `:model_loading`. `model_status/0` gains `provider` kind field.
- Alternative: separate `Embedder`/`Reranker` ports — rejected for now; `Core.Inference` already splits embed vs summarize and `validate!/0` covers it. Reranker stays a future callback addition, noted in Open Questions.

### 3. Code and Hex content are ordinary documents, not new stores
Elixir indexer (`Code.string_to_quoted/2`, `Mix.Project`, `.beam` chunks where cheap) writes L2 sources plus derived structural facts under `viking://resources/<project>/code/` via `put_document/3`, reusing embedding jobs for semantic reachability but serving structural queries (`callers`, `supervision chain`) from stored metadata without inference. Hex importer reads `mix.lock` offline, caches docs under `data_dir/hex/<pkg>/<version>/`, and boosts locked-version scores in `Search` RRF fusion rather than forking the index.
- Alternative: separate code/hex tables — rejected, would break removal-completeness and `find/grep` uniformity.

### 4. BEAM snapshots are on-demand and optionally persisted
`AgentDb.Runtime.Context.snapshot/1` gathers `:application`, supervisor children, `Process.info` (reductions/mailbox/current_function), `ETS.info` sizes, `:memory`, telemetry counters via existing `Observability`, truncating at fixed bounds with `truncated: true`. Never auto-writes; caller may `write/2` the rendered markdown if durable history is wanted.
- Alternative: background sampler writing snapshots — rejected, unbounded growth and privacy risk.

### 5. Channel adds `v1.subscribe/unsubscribe` + progress pushes in existing envelope
Progress (`retrieval_started/progress/resource_found/memory_found/skill_loaded/context_ready`) pushes as channel messages on the caller's topic; final `search` reply keeps its envelope. Invalid subscribe returns `{:error, :invalid_uri}` via `answer/2`, preserving connection usability.

### 6. OTel wraps existing `Search` stages with bounded attributes
Wrap intent/resource/memory/skill/embedding/rerank/assembly stages using current `Observability` span helpers; propagate stored `_trace` from job payloads. No URIs/content/prompts as attributes — stage/mode/outcome only, matching current telemetry redaction.

### 7. Mix tasks reuse the `AgentDb` facade
`mix agent_db.index/search/tree/doctor` start the app and call `AgentDb.*` directly (same pattern as `agent_db.import_skills`), so console, WS, and CLI share one workflow.

## Risks / Trade-offs

- [PubSub fan-out on hot URIs] → Mitigation: per-URI topics, no persistence, slow-consumer drop with counter; writers never block.
- [AST indexing cost on large repos] → Mitigation: file-level idempotency, per-file error isolation, `mix agent_db.index` incremental by mtime/hash; no embedding required for structural queries.
- [HexDocs size explosion] → Mitigation: cache only locked versions by default, byte/entry caps mirroring skills importer limits, offline-first.
- [Snapshot cardinality/PII] → Mitigation: fixed bounds, truncation flag, redaction of bodies/contents/credentials enforced in snapshot module tests.
- [Remote provider latency/keys] → Mitigation: bounded timeouts, existing `:model_loading`/retry/defer contracts reused, keys only from env/config with redacted logs.
- [Version boost skewing hybrid ranking] → Mitigation: boost as additive RRF bonus for exact locked-version matches, documented and tested against 1.7/1.8/1.9 fixture.

## Migration Plan

- Additive only: no SQLite migration; new subtrees (`code/`, `hex/`), new optional config keys (`:embedding_provider`, `:summarizer_provider`), new channel events, new Mix tasks.
- Deploy: ship with defaults (local inference, subscriptions enabled in-process); existing data_dir reused.
- Rollback: unset provider keys to restore local default; delete `code/`/`hex/` subtrees via existing `rm/1` (removal-completeness covers vector index + jobs); unsubscribe clients fall back to polling. No durable subscription state to clean.

## Open Questions

- Should `Summarizer` gain a `rerank/2` callback now or in the follow-up distribution change?
- Exact `mix agent_db.doctor` check list (index freshness, provider reachability, PubSub health) — safe to finalize during tasks without changing specs.
- Whether snapshot persistence deserves a `viking://runtime/` convention vs caller-chosen URIs.
