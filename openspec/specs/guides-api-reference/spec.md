# guides-api-reference Specification

## Purpose

Provides a complete machine-readable reference for all public interfaces — the Elixir `AgentDb` module API, CLI tasks (`mix agent_db.*`), MCP tools, and WebSocket `v1.*` events — with request/response shapes, error codes, pagination limits, and option catalogs so developers can integrate without reading source code. Surfaces that already have a generated catalog point at it instead of duplicating it; only surfaces nothing generates are documented by hand, each with its code source of truth named.

## Requirements

### Requirement: API reference maps the Elixir AgentDb module API to the generated documentation
The system SHALL provide `guides/API-REFERENCE.md` with, for each public entry point of the `AgentDb` module, the domain it belongs to, its governing spec, and a link to the generated API documentation (hexdocs or local `mix docs`). The entry-point set is defined by the code. The guide SHALL NOT hand-copy signatures, options, or return shapes: the generated docs are the single non-drifting catalog, and coverage of every public function is verified by the `mix docs` build, not by prose.

#### Scenario: Developer looks up search options without source code
- **WHEN** a developer reads the entry covering `AgentDb.search/2` in `guides/API-REFERENCE.md`
- **THEN** they see which capability it belongs to (search over the tree), the mode options summarised at a glance (`:keyword`, `:vector`, `:hybrid`), and a link to the generated docs where full signatures, options, success tuples `{:ok, [%{uri, score, ...}]}`, and error tuples such as `{:error, :model_loading}` and `{:error, {:invalid_limit, _}}` live
- **AND** no signature is hand-copied into the guide, so nothing in it can contradict the code

#### Scenario: Developer discovers memory confidence bounds
- **WHEN** a developer reads the entry covering `AgentDb.remember/3`
- **THEN** they see that `confidence:` (0.0–1.0, default 0.5), `importance:` (0.0–1.0, default 0.5), and the `candidate:` flag are documented in the generated entry for the function, with a link to it

### Requirement: API reference documents all CLI tasks with flags and JSON output
The system SHALL document every `mix agent_db.*` task defined in `lib/mix/tasks/` (at the time of writing: `doctor`, `read`, `search`, `find`, `grep`, `tree`, `recall`, `index`, `import_skills`, `import_data`, `export_data`, `seed`) with each task's switches as declared in its `@switches` (which may include `--no-compile`), the human-readable and JSON output shapes, and exit codes. The directory is the normative source: a task added or a switch renamed without a guide update is a failed review.

#### Scenario: Automation script uses CLI with --json
- **WHEN** a developer reads the `mix agent_db.search` entry in `guides/API-REFERENCE.md`
- **THEN** they see the task's switches (`--mode`, `--scope`, `--top-k`, `--json`, `--no-compile`), the JSON stdout shape on success, the stderr shape on failure, and that non-zero exit means failure

#### Scenario: Guide reflects the task directory rather than memory
- **WHEN** a reviewer compares the CLI section against `lib/mix/tasks/`
- **THEN** every task in the directory has an entry, and each document switch exists in that task's `@switches` — `agent_db.seed` is documented as a task like any other

### Requirement: API reference documents MCP tools with request/response schemas
The system SHALL document every tool in the `AgentDbWeb.Mcp.tools/0` registry (at the time of writing: the eight `context_*` tools, `memory_recall`/`memory_remember`/`memory_forget`, `session_create`/`session_append`/`session_get`/`session_commit`, `store_health`) with the request schema as the tool declares it, the success response, and the error response. The registry is the normative source; a tool not in `tools/0` SHALL NOT appear in the guide.

#### Scenario: MCP client developer implements tool calls
- **WHEN** a developer reads the `context_search` tool entry
- **THEN** they see the flat request schema the tool declares (`term`, optional `mode`, `scope`, `top_k`), the success response `{results: [...]}`, and the error response `{code, message}` with codes like `model_loading`, `invalid_limit`

#### Scenario: Registry changes force a guide change
- **WHEN** a tool is added to `AgentDbWeb.Mcp.tools/0` in a later change
- **THEN** the same change updates `guides/API-REFERENCE.md`, or the review requirement in the usage-guides spec fails

### Requirement: API reference documents WebSocket v1.* events with payload schemas
The system SHALL document every incoming `v1.*` event the channel handles in `lib/agent_db_web/channel.ex`, each with payload schema, response event, and error event schema. It SHALL document subscription semantics (per-connection, not surviving reconnect), the pushed-only responses (`v1.append_message`, `v1.commit_session`, `v1.context_changed`), and the `traceparent` forms `Observability.extract_context/1` accepts (HTTP header, payload top level, `opts`).

#### Scenario: WebSocket client developer implements subscription
- **WHEN** a developer reads the `v1.subscribe` entry
- **THEN** they see the request `{event: "v1.subscribe", payload: {uri: "..."}}`, the ack response, the push event `{event: "v1.context_changed", payload: {uri, kind, version}}`, and that subscriptions are per-connection and do not survive reconnect

#### Scenario: Handler set is checked against the channel, not memory
- **WHEN** a reviewer compares the event list against `lib/agent_db_web/channel.ex`
- **THEN** every handled `v1.*` event in the file (at the time of writing: `v1.write`, `v1.read`, `v1.abstract`, `v1.overview`, `v1.list`, `v1.tree`, `v1.rm`, `v1.search`, `v1.find`, `v1.grep`, `v1.remember`, `v1.recall`, `v1.forget`, `v1.create_session`, `v1.get_session`, `v1.model_status`, `v1.health`, `v1.subscribe`, `v1.unsubscribe`, `v1.search_progress`) appears in the guide, and every event in the guide is handled in the file — pushed-only events (append_message, commit_session) are labelled as responses, not as events a client may send

### Requirement: API reference includes a unified error code catalog
The system SHALL provide a single table mapping every error code used across the transports to its HTTP-style classification, where it appears, and a one-line description. The code set is the `AgentDb.Observability` taxonomy (`classify_reason/1`, the caller-error tags, `http_status/1`); codes no transport emits SHALL NOT appear. Verification: every listed code exists in the taxonomy and is reachable from a transport; the runtime-observability spec mandates it, so the module is the source.

#### Scenario: Developer handles errors uniformly across transports
- **WHEN** a developer reads the error code catalog
- **THEN** they can write a single error-handling switch that covers Elixir tuples, CLI stderr, MCP error responses, and WebSocket error events
- **AND** an operator reusing the catalog for alerting matches codes that telemetry and logs actually emit

#### Scenario: Catalog audit rejects phantom codes
- **WHEN** a reviewer audits the catalog against `AgentDb.Observability`
- **THEN** every row exists in the taxonomy (for example `not_found`, `invalid_limit`, `model_loading`, `inference_timeout`, `download_failed`), and no invented code (for example `provider_unreachable` or `queue_backpressure`, which the code never emits) appears
