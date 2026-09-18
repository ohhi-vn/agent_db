# Change: Offline Agent Store (OpenViking-Inspired, Elixir/OTP)

## Why

AI agents need durable context - resources, memories, skills - that survives restarts and stays queryable fully offline. Existing context databases such as OpenViking are heavy server stacks (Python/Rust, vector DBs, LLM providers). There is no simple Elixir/OTP equivalent a single-node app can embed. This change creates an embedded, offline-first context store: OTP supervision, SQLite as the durable source of truth, and ETS caches for hot reads. No LLM, embeddings, or network services anywhere.

## What Changes

- New Elixir/OTP application `:agent_db` providing an OpenViking-inspired context store:
  - Hierarchical context tree addressed by `viking://`-style URIs with `resources/`, `user/{user_id}/memories|resources|skills`, and `peers/` subtrees.
  - Caller-supplied content: writers provide full content (L2) plus optional caller-authored `abstract` (L0) and `overview` (L1) summaries. The store never calls an LLM.
  - SQLite (via `exqlite`) as the single source of truth for tree structure, content, and sessions; ETS holds only disposable hot-path caches.
  - Progressive loading: `abstract`/`overview` reads serve the caller-supplied L0/L1; `read` serves full L2 content.
  - Keyword search: case-insensitive substring match over content and summaries, optionally scoped to a subtree.
  - Sessions: append-only message log persisted in SQLite; `commit` converts a session into a context document at a caller-chosen destination URI.
  - Caching: read path is ETS-first with SQLite fallback; writes persist first, then update caches, so a crash between the two never leaves a cache ahead of disk.
- Single-node embedded deployment; no server process, HTTP API, or multi-tenancy networking.

## Capabilities

### New Capabilities

- `context-store`: Hierarchical persistent context store: viking-style URI tree, caller-supplied L0/L1/L2 content, keyword search, and sessions with commit-to-context.

### Modified Capabilities

None.

## Impact

- **New code**: `mix.exs` Mix project `agent_db`; `lib/agent_db/**` with supervision tree, storage layer, cache layer, and public API modules; `test/agent_db/**` for ExUnit coverage.
- **Dependencies**: adds `exqlite` for SQLite (native NIF driver accepted as the single non-pure-Elixir boundary; all application logic remains Elixir). No Ecto.
- **Runtime**: new supervision tree (SQLite connection process, ETS cache owner) under `AgentDb.Application`; SQLite files live under `data/`.
- **No network**: no HTTP endpoints, no external services, no telemetry backends.

## Non-Goals

- No vector search, embeddings, rerank, or ranking services.
- No LLM-driven summaries or memory extraction (callers supply content and summaries).
- No HTTP server, MCP integration, or multi-tenant networking.
- No replication or multi-node coordination (single-node embedded store).
- Not an OpenViking server API-compatible port - inspiration, not a clone.
