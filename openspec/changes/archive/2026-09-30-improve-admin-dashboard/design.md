# Design

## Context

See proposal.md - Why. Current state: `AgentDbWeb.AdminLive` mounts with `page`, `user_id`, `results`, `limits`, loads via `Context.list_documents(page 50)`, `Context.model_status()`, `Context.job_stats()`, and refreshes on a 30s `:timer.send_interval`. It never subscribes despite `AgentDb.subscribe/1` + `AgentDb.PubSub` publishing `{:context_changed, uri, kind, version}` to the changed URI and every ancestor up to `viking://` (see `lib/agent_db/subscriptions.ex`). Rich answers already exist behind `Context` (`search_documents`, full `model_status` with loading/latency/memory/param size, `health_check`, `get_session`) but the template renders only state+loaded and queue counts.

## Goals / Non-Goals

**Goals:**
- Realtime console with no new backend index, no new dependencies, no contract breaks.
- Surface already-available info (search, full model/queue/health, recent changes, session-by-ID) through the existing facade.

**Non-Goals:**
- New session listing index, new REST/WS/MCP contracts, auth changes, design-system overhaul (see proposal.md Non-goals). No change to `context-subscriptions` delivery semantics.

## Decisions

### 1. Subscribe to the tree root via the facade; keep the timer as fallback

- On `connected?` mount, call `AgentDb.subscribe("viking://")` (root; `Subscriptions.scopes/1` publishes every change to all ancestors including root, so one subscription sees all writes/removals/replacements/commits). `handle_info({:context_changed, uri, kind, version}, socket)` reloads affected assigns and prepends a bounded recent-feed entry (cap ~20, no content).
- Keep the existing 30s `:refresh` as convergence fallback for missed events/reconnects. Unsubscribe on terminate is automatic (process-scoped PubSub).
- Alternatives considered: direct `Phoenix.PubSub.subscribe` to internal topic — rejected, bypasses URI validation and couples the view to topic naming; subscribing per-subtree (resources, memories, skills) — rejected, needs N subscriptions and still misses new top-level subtrees; removing the timer entirely — rejected, a missed broadcast would diverge the view silently.

### 2. Single AdminLive first; extract narrow views only if unwieldy

- Extend `AdminLive` with search, status, health, feed, and session-lookup sections. Extract to `SessionLive` / `SearchLive` under `/admin/*` only if the template/handlers exceed comfortable review size. All views stay in the `:browser` pipeline and talk to the store only via `AgentDbWeb.Context`.
- Alternative (new LiveViews upfront) rejected: speculative scaffolding; proposal allows at most two additive views.

### 3. Search defaults to keyword; vector/hybrid passed through

- Search box calls `Context.search_documents(term, mode: keyword, top_k: 10)` by default so it works with no model loaded. Mode selector (if added) passes the string through so the store reports invalid modes itself, matching `Context.search_documents` behavior. Failures render in words and preserve the current listing.
- Alternative (vector-default) rejected: would make search unusable offline and contradict the store's deferred-vs-failed distinction.

### 4. Render full status maps; formatting helpers only in Context

- Template renders the complete `model_status()` per-role map (state including load-in-progress, `last_latency_ms`, memory, configured param size), full `job_stats()` breakdown, and `health_check()`. Any new `Context` functions are pure presentation shapers over existing facade returns — no DB or model-manager reads from the web layer.
- Session lookup uses `Context.get_session(id)` directly; no new index or list endpoint.

### 5. Backend latency/memory read-out lives in ModelManager (Option 2 scope)

- `run_inference/3` already measures each inference duration and discards it. Thread the role through (`run_inference/4`), record the duration per role in manager state on every inference run (success or failure — it is still the last latency), and report per-role `last_latency_ms` in `build_model_status/1` (`nil` until a role first runs). Loads are excluded: the contract is last *inference* latency.
- Report VM memory once at the top level as `memory_bytes` from `:erlang.memory(:total)` (same source as `RuntimeContext` snapshots), rescued to `nil`. Per-role memory is not measurable and is not reported; the console labels the figure as a BEAM total.
- Remote backends (Ollama, OpenAI-compatible) keep their static maps; absent keys render as "not reported" in the console rather than forcing every backend to invent figures.
- Alternatives considered: an Observability ETS last-value cache — rejected, a second source of truth needing lifecycle management when the manager already measures durations; per-role memory split — rejected, fabrication without backend support.
- No `http-api` delta needed: its model-status requirement already calls for latency/memory; this aligns the implementation with it.

## Risks / Trade-offs

- [Bulk import floods events → view reload storms] → Mitigation: coalesce rapid `handle_info` bursts (e.g., reload at most once per ~500ms–1s window, always apply latest feed entries).
- [Root subscription receives every change on busy stores] → Mitigation: feed is bounded and reload reuses existing paged queries (50 docs, top_k 10); no extra queries per event beyond the current `load/1`.
- [Async-event test flakiness] → Mitigation: LiveView tests assert eventual convergence (fallback timer + direct `send(view.pid, {:context_changed, ...})`), not exact timing; keep existing deterministic import tests untouched.
- [Stale feed after restart] → Accepted: matches `context-subscriptions` non-durable semantics; fallback refresh repopulates from current state.

## Migration Plan

Additive only: no DB migration, no config change, no route removal. Deploy normally; rollback by reverting the change. Existing `/admin`, editor, skill import, and `/mcp` behavior unchanged and covered by existing tests.
