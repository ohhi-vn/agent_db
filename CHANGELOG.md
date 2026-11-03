# Changelog

All notable changes to AgentDb are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, breaking changes increment the minor version.

## [0.2.0] - Unreleased

### Added

- Added [daisyUI](https://daisyui.com/) to the console's asset toolchain as an npm
  dependency, layered on the existing Tailwind pipeline. The default theme is
  `light`; `mix assets.build` and `mix assets.deploy` reproduce the committed
  stylesheet.

### Changed

- Redesigned the `/admin` operations console on daisyUI. The shell now uses
  daisyUI drawer/navbar/menu primitives, and every console page and shared
  component — including search, model/queue/health/runtime status, and the
  document editor — uses the same component vocabulary.
- Replaced the bespoke `admin-card-*` scheme and mixed gray/blue utilities with
  semantic daisyUI tokens (`base-*`, `primary`, `success`, `warning`, `error`,
  `info`), so the selected theme applies consistently across all pages.
- Removed CSS rules left unused by the migration and regenerated
  `priv/static/assets/app.css`.
- Documented the daisyUI dependency, default theme, and stylesheet rebuild step
  in `guides/SETUP.md`.

### Fixed

- Finished migrating pages and the document editor that still used the old
  bespoke styling, fixing inconsistent spacing, colors, and affordances. Status
  text (enabled/disabled, health, queue availability) now uses semantic status
  colors.

## [0.1.0] - 2026-10-31

Initial public release.

### Added

- **Context store** — an embedded, offline `viking://` context tree
  (`resources/`, `user/{id}/memories`, `user/{id}/resources`, `user/{id}/skills`,
  `peers/`) persisted in SQLite with ETS read-through caching and OTP supervision.
- **Layered content** — full content (L2) plus caller-supplied or LLM-generated
  abstract (L0) and overview (L1), readable individually or in batches.
- **Keyword search, `find`, and `grep`** — case-insensitive keyword search over
  content and summaries, URI-path discovery, and L2 line matching, each
  subtree-scoped and bounded.
- **Vector and hybrid search** — a sqlite-vec HNSW index with per-provider,
  dimension-namespaced embedding tables; hybrid retrieval combines keyword and
  vector results using Reciprocal Rank Fusion.
- **Asynchronous writes** — a durable queue for embedding and summarization jobs,
  immediate acknowledgement by default, and explicit completed/failed/pending
  outcomes for synchronous writes.
- **Sessions** — append-only message logs with commit-to-context-tree, including
  correct read-through cache invalidation after a commit.
- **Memory** — typed, durable facts under `viking://user/memories/` with
  confidence, importance, provenance, and supersession; candidate
  promotion/rejection, conflict surfacing, decay-aware recall, and statistics, all
  without a model.
- **Agent Skills** — import one skill or a collection from a folder, tar, or
  tar.gz through the API, console, or `mix agent_db.import_skills`, with full
  validation, per-skill atomic replacement, and explicit size limits.
- **Data portability** — `export_data`/`import_data` archives documents, memory
  provenance, and sessions into a manifest-backed tar that is validated end to
  end before any write, plus matching Mix tasks.
- **WebSocket API** — a Phoenix Channel at `/api` with `v1.*` operations and
  optional Bearer authentication.
- **HTTP, MCP, and sidecar** — REST endpoints, a Streamable HTTP MCP endpoint at
  `/mcp`, and an in-process `AgentDb.Mcp` tool inventory and dispatch
  (`tools/0`, `call_tool/3`) for embedded sidecar use.
- **Command line** — `mix agent_db.*` tasks for read, abstract, overview, search,
  find, grep, recall, tree, index, seed, doctor, skill import, and data transfer,
  with `--json` output for machine consumers.
- **Agent tooling** — copy-paste OpenCode and Zed MCP setup, `tools/install.sh`
  and `install.ps1` checks, and guidance that keeps the daemon loopback-only by
  default.
- **Reactive subscriptions** — `subscribe/1` and `unsubscribe/1` with versioned
  `{:context_changed, uri, kind, version}` events for writes, removals,
  replacements, and commits.
- **Elixir code index** — structural indexing of `.ex`/`.exs` sources with
  OTP-aware caller/callee and behaviour relationships, no model required.
- **Hex docs context** — offline discovery of installed package documentation
  from `mix.lock`, with installed-version-aware retrieval.
- **BEAM runtime snapshots** — bounded, redacted, read-only snapshots of
  applications, supervisors, processes, ETS, and memory.
- **Pluggable inference** — local Nx/Bumblebee/EXLA by default, optional EMLX
  acceleration on Apple Silicon, and opt-in Ollama and OpenAI-compatible
  adapters; `all-MiniLM-L6-v2` embeddings and `Qwen3-0.6B` summarization load
  lazily and cache locally.
- **Operations console** — `/admin` pages for overview, documents, storage,
  skills, sessions, and memories, plus a document editor. The overview reports
  model, queue, health, runtime, and recent-change status.
- **Observability** — telemetry events with bounded dimensions, OpenTelemetry
  spans and W3C trace propagation into durable jobs, structured logs with
  credential redaction, health and doctor checks, and repeatable benchmarks.
- **Packaging and delivery** — Hex package metadata, generated ExDoc guides and
  module reference, CI verification, a trusted-publishing release workflow, and
  secret scanning.
