# Proposal

## Why

`/admin` is the operator's only view of the store, but it refreshes on a 30s timer and shows a thin slice (root document page, coarse model/queue counts). The store already publishes versioned change events over PubSub and already answers richer questions (search, model loading/latency/memory, health, document layers), so the console lags reality and hides information the backend already has. Operators miss writes, removals, skill replacements, and session commits between polls.

## What Changes

- **Realtime console:** `AdminLive` subscribes to context changes via the existing `AgentDb.subscribe`/PubSub path on connect, re-renders affected sections on `handle_info`, and keeps the 30s timer only as a reconnect/fallback refresh. Subscription lifetime follows the LiveView process; restart requires resubscribe.
- **Richer operations info (one small facade extension):**
  - Document search box (keyword, scoped) + result list linking to existing editor; keep 50/page pagination for the tree root.
  - Full model status (loading state, last inference latency, memory, param size) — latency/memory are added to `ModelManager.model_status()` (per-role last inference duration it already measures; VM memory total), since no existing call answers them.
  - Full queue breakdown from `Context.job_stats()` plus health from `Context.health_check()`.
  - Recent-change feed (URI, kind `written | removed | replaced | committed`, version) from subscribed events; events carry no content.
  - Session lookup by ID via existing `Context.get_session/1` (no new session index in this change).
- **LiveView structure:** Keep `live("/admin", AdminLive)`. Add at most two narrow LiveViews under `/admin/*` (e.g., search-focused tab or session viewer) only if a single view becomes unwieldy; same `:browser` pipeline, same auth, same `Context` facade.
- **Non-goals:** No auth/policy changes, no new `/api` or `/mcp` contracts, no new session listing index, no visual design system overhaul, no Phoenix.LiveDashboard changes.

## Capabilities

### New Capabilities

- `admin-dashboard`: realtime operations console behavior at `/admin` — PubSub-driven refresh, searchable/richer document, model, queue, health, and recent-change presentation through the existing `Context` facade.

### Modified Capabilities

<!-- None — this change consumes existing `context-subscriptions`, `context-store`, and `http-api` contracts without changing their REQUIREMENTS. -->

## Impact

- Affected: `lib/agent_db_web/live/admin_live.ex` (+ possible 1–2 new LiveViews under same dir), `lib/agent_db_web/router.ex` (additive `/admin/*` lives only), `lib/agent_db_web/context.ex` (additive presentation helpers only), `test/agent_db_web/live/admin_live_test.exs` (+ new live tests).
- No change to `AgentDb` facade contracts, auth plugs, WebSocket `v1.*`, REST, or `/mcp`. No new dependencies; uses existing `Phoenix.PubSub` and `AgentDb.subscribe`.
