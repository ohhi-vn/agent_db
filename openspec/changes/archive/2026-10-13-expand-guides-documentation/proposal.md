# Proposal

## Why

The current guides in `guides/` cover quickstart, setup, usage, and agent integration but lack dedicated deep-dive guides for architecture, monitoring/observability, API reference, and troubleshooting. Users who want to understand the system internals, set up production monitoring, or debug issues must piece together information from specs, code, and scattered comments. This change adds structured, task-oriented guides that complement the existing user-facing documentation.

Commit `da5adc6` renamed `docs/` to `guides/` as pure renames, and every system that names the docs directory went stale at the same moment: `mix docs` crashes on `docs/QUICKSTART.md` because the `mix.exs` extras list still points at the old paths (verified locally), the Hex package declares and requires a `docs` directory that no longer exists (`package()` files list and `tools/verify_package.exs`), the root `README.md` carries 13 dead `docs/` links, the guides cross-reference each other through `docs/` in 10 more places, and the `usage-guides` spec of record still asserts `docs/` paths. Since `mix docs` is also the CI documentation gate, the repository cannot currently verify its own documentation. Repairing the rename is a prerequisite for the guides this change adds.

Separately, the catalogs that exist were written from memory rather than from code. `guides/MONITORING.md` lists error codes no transport emits and shows a Prometheus alert query on one of them; `guides/USAGE.md` and `guides/agents.md` list MCP tools that do not exist; and this change's own delta specs enumerate function, task, tool, event, and code lists that disagree with `lib/` in every category. A hand-written Elixir API catalog would start stale on arrival: the root README's stated stance is that the API reference is generated from the code and therefore cannot drift. This change adopts that discipline everywhere a generated surface exists and documents by hand only what nothing generates.

## What Changes

- **New guide: `guides/ARCHITECTURE.md`** (tasks 1.x, complete) — system architecture overview covering the context store, memory system, inference pipeline, background job queue, and transport layers (HTTP, WebSocket, MCP). Explains data flows and component boundaries.
- **New guide: `guides/MONITORING.md`** (tasks 2.x, complete) — production monitoring and observability guide covering the `/admin` console, telemetry events, structured logs, health checks, error taxonomy, and alerting recommendations, plus the catalog repairs in task 1.5 so its error codes match the `AgentDb.Observability` taxonomy and its alert examples query codes that are actually emitted.
- **New guide: `guides/API-REFERENCE.md`** — a reference guide shaped per surface: the Elixir `AgentDb` module API maps into the generated documentation (hexdocs, or `mix docs` locally) instead of hand-copying signatures; the CLI, MCP, and WebSocket sections are written by hand because no generated surface exists for them, each naming its code source of truth (`lib/mix/tasks/` and `@switches`, `AgentDbWeb.Mcp.tools/0`, `lib/agent_db_web/channel.ex`); the unified error catalog is the shared `AgentDb.Observability` taxonomy mapped across transports.
- **New guide: `guides/TROUBLESHOOTING.md`** — common issues and resolutions organized by symptom: model loading failures, database errors, queue backpressure, inference latency, authentication issues, and WSL2-specific problems. Includes diagnostic commands and log interpretation.
- **New guide: `guides/README.md`** — guide index with descriptions and audience for each guide, so users find the right document quickly; the root README links through it.
- **Repair the `da5adc6` rename fallout** — `mix.exs` (docs extras and package file list), `tools/verify_package.exs` (`@required`), `tools/install.sh` and `tools/install.ps1` message strings, root `README.md` links, and the `guides/USAGE.md` / `guides/QUICKSTART.md` / `guides/SETUP.md` cross-references.
- **Repair the shipped phantom catalogs** — the three error codes and the alert example in `guides/MONITORING.md` that the `AgentDb.Observability` taxonomy does not emit (`enqueue_failed`, `storage_error`, `provider_unreachable`), restored to the taxonomy's actual codes and the provider health state (`model_status/0` reporting `:unreachable`).
- **Update `guides/README.md` index** — as above, part of the guide set.

## Capabilities

### New Capabilities

- `guides/architecture`: System architecture documentation for operators and developers who need to understand component boundaries, data flows, and deployment topology.
- `guides/monitoring`: Production monitoring, observability, and alerting guidance connecting the runtime-observability and admin-dashboard specs to operational practice.
- `guides/api-reference`: Complete reference for all public interfaces — Elixir API, CLI, MCP, WebSocket — with the Elixir API served by the generated documentation and the remaining transports documented by hand with named sources, plus the unified error-code catalog.
- `guides/troubleshooting`: Symptom-driven diagnostic guide with resolutions and diagnostic commands.

### Modified Capabilities

- `usage-guides`: The existing `usage-guides` spec (at `openspec/specs/usage-guides/spec.md`) will be updated to include the new guides in its discovery and verification requirements, and to restore the `guides/` paths the `da5adc6` rename left stale in its requirements. The spec currently requires three guides (QUICKSTART, SETUP, USAGE) plus agents.md; it will be extended to require the four new guides and the index README, and to point at `guides/` rather than `docs/`.

## Impact

- **Files created**: `guides/API-REFERENCE.md`, `guides/TROUBLESHOOTING.md`, `guides/README.md`
- **Files modified**: `mix.exs`, `tools/verify_package.exs`, `tools/install.sh`, `tools/install.ps1`, `README.md`, `guides/USAGE.md`, `guides/QUICKSTART.md`, `guides/SETUP.md`, `guides/MONITORING.md`, `guides/agents.md`, `openspec/specs/usage-guides/spec.md`
- **No runtime code changes**: this change edits no library behavior, action, or data model. What does change is build and packaging configuration (`mix.exs` docs extras and package file list, `verify_package.exs`) and two installer message strings — all consequences of repairing the rename fallout.
- **Dependencies**: none new. Guides reference existing specs (context-store, memory, runtime-observability, admin-dashboard, inference-providers, http-api, agent-tooling) and existing code surfaces.
