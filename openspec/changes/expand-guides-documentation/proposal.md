# Proposal

## Why

The current guides in `guides/` cover quickstart, setup, usage, and agent integration but lack dedicated deep-dive guides for architecture, monitoring/observability, API reference, and troubleshooting. Users who want to understand the system internals, set up production monitoring, or debug issues must piece together information from specs, code, and scattered comments. This change adds structured, task-oriented guides that complement the existing user-facing documentation.

## What Changes

- **New guide: `guides/ARCHITECTURE.md`** — System architecture overview covering the context store, memory system, inference pipeline, background job queue, and transport layers (HTTP, WebSocket, MCP). Explains data flows and component boundaries.
- **New guide: `guides/MONITORING.md`** — Production monitoring and observability guide covering the `/admin` console, telemetry events, structured logs, health checks, error taxonomy, and alerting recommendations. Connects runtime-observability spec to operational practice.
- **New guide: `guides/API-REFERENCE.md`** — Complete reference for the public Elixir API (`AgentDb` module), CLI tasks (`mix agent_db.*`), MCP tools, and WebSocket `v1.*` events with request/response shapes, error codes, and pagination limits.
- **New guide: `guides/TROUBLESHOOTING.md`** — Common issues and resolutions organized by symptom: model loading failures, database errors, queue backpressure, inference latency, authentication issues, and WSL2-specific problems. Includes diagnostic commands and log interpretation.
- **Update `guides/README.md`** — Add a guide index with descriptions and audience for each guide so users can find the right document quickly.

## Capabilities

### New Capabilities

- `guides/architecture`: System architecture documentation for operators and developers who need to understand component boundaries, data flows, and deployment topology.
- `guides/monitoring`: Production monitoring, observability, and alerting guidance connecting the runtime-observability and admin-dashboard specs to operational practice.
- `guides/api-reference`: Complete machine-readable reference for all public interfaces (Elixir API, CLI, MCP, WebSocket) with schemas, error codes, and limits.
- `guides/troubleshooting`: Symptom-driven diagnostic guide with resolutions and diagnostic commands.

### Modified Capabilities

- `usage-guides`: The existing `usage-guides` spec (at `openspec/specs/usage-guides/spec.md`) will be updated to include the new guides in its discovery and verification requirements. The spec currently requires three guides (QUICKSTART, SETUP, USAGE) plus agents.md; it will be extended to require the four new guides and the index README.

## Impact

- **Files created**: `guides/ARCHITECTURE.md`, `guides/MONITORING.md`, `guides/API-REFERENCE.md`, `guides/TROUBLESHOOTING.md`, `guides/README.md`
- **Files modified**: `openspec/specs/usage-guides/spec.md` (delta spec to extend requirements)
- **No code changes**: This is a documentation-only change. No runtime behavior, APIs, or data models are modified.
- **Dependencies**: None new. Guides reference existing specs (context-store, memory, runtime-observability, admin-dashboard, inference-providers, http-api, agent-tooling) and existing code surfaces.