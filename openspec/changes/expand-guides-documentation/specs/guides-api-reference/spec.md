# Spec Delta

## Purpose

Provides a complete machine-readable reference for all public interfaces — the Elixir `AgentDb` module API, CLI tasks (`mix agent_db.*`), MCP tools, and WebSocket `v1.*` events — with request/response shapes, error codes, pagination limits, and option catalogs so developers can integrate without reading source code.

## ADDED Requirements

### Requirement: API reference documents the Elixir AgentDb module public API
The system SHALL provide `guides/API-REFERENCE.md` with a complete catalog of `AgentDb` public functions: `write/3`, `read/1`, `abstract/1`, `overview/1`, `list/1`, `tree/2`, `rm/1`, `search/3`, `find/2`, `grep/2`, `remember/3`, `recall/1`, `forget/1`, `promote_memory/1`, `reject_memory_candidate/1`, `pending_memory_candidates/0`, `memory_conflicts/0`, `create_session/0`, `append_message/3`, `get_session/1`, `commit_session/2`, `import_skills/2`, `export_data/1`, `export_data/2`, `import_data/1`, `health_check/0`, `model_status/0`, `queue_stats/0`, `subscribe/1`, `unsubscribe/1`. Each entry SHALL include the function signature, all options with types and defaults, success and error return shapes, and cross-references to the governing spec.

#### Scenario: Developer looks up search options without source code
- **WHEN** a developer reads the `AgentDb.search/3` entry in `guides/API-REFERENCE.md`
- **THEN** they see the `mode:` options (`:keyword`, `:vector`, `:hybrid`), `scope:`, `top_k:`, `hybrid_weights:`, the success tuple `{:ok, [%{uri, score, ...}]}`, and error tuples (`{:error, :model_loading}`, `{:error, {:invalid_limit, _}}`)

#### Scenario: Developer discovers memory confidence bounds
- **WHEN** a developer reads the `AgentDb.remember/3` entry
- **THEN** they see `confidence:` range 0.0–1.0 (default 0.5), `importance:` range 0.0–1.0 (default 0.5), and the `candidate:` flag behavior

### Requirement: API reference documents all CLI tasks with flags and JSON output
The system SHALL document every `mix agent_db.*` task (`read`, `search`, `find`, `grep`, `recall`, `tree`, `index`, `import_skills`, `import_data`, `export_data`, `doctor`) with all flags (`--mode`, `--scope`, `--top-k`, `--limit`, `--depth`, `--type`, `--term`, `--include-superseded`, `--project`, `--dir`, `--user`, `--json`), the human-readable and JSON output shapes, and exit codes.

#### Scenario: Automation script uses CLI with --json
- **WHEN** a developer reads the `mix agent_db.search` entry
- **THEN** they see the exact flag names, the JSON stdout shape on success, the stderr shape on failure, and that non-zero exit means failure

### Requirement: API reference documents MCP tools with request/response schemas
The system SHALL document every MCP tool (`context_read`, `context_write`, `context_rm`, `context_list`, `context_tree`, `context_search`, `context_find`, `context_grep`, `memory_recall`, `memory_remember`, `memory_forget`, `session_create`, `session_append`, `session_get`, `session_commit`, `store_health`) with the JSON request schema, success response schema, and error response schema (including the bounded `code` field from the shared taxonomy).

#### Scenario: MCP client developer implements tool calls
- **WHEN** a developer reads the `context_search` tool entry
- **THEN** they see the request object `{term, opts: {mode, scope, top_k, hybrid_weights}}`, the success response `{results: [...]}`, and the error response `{code, message}` with codes like `model_loading`, `invalid_limit`

### Requirement: API reference documents WebSocket v1.* events with payload schemas
The system SHALL document every WebSocket event (`v1.write`, `v1.read`, `v1.search`, `v1.find`, `v1.grep`, `v1.create_session`, `v1.append_message`, `v1.get_session`, `v1.commit_session`, `v1.model_status`, `v1.subscribe`, `v1.unsubscribe`, `v1.search_progress`) with the event name, payload schema, response event name, response payload schema, and error event schema. It SHALL document the `traceparent` propagation rules (top-level, inside `opts`, or HTTP header) and subscription semantics.

#### Scenario: WebSocket client developer implements subscription
- **WHEN** a developer reads the `v1.subscribe` entry
- **THEN** they see the request `{event: "v1.subscribe", payload: {uri: "..."}}`, the ack response, the push event `{event: "v1.context_changed", payload: {uri, kind, version}}`, and that subscriptions are per-connection and do not survive reconnect

### Requirement: API reference includes a unified error code catalog
The system SHALL provide a single table mapping every error code used across Elixir API, CLI, MCP, and WebSocket to its HTTP-style classification, the transports where it appears, and a one-line description. Codes SHALL include at minimum: `not_found`, `invalid_limit`, `invalid_query`, `model_loading`, `embeddings_unavailable`, `provider_unreachable`, `inference_timeout`, `queue_backpressure`, `enqueue_failed`, `storage_error`, `auth_required`, `skill_refused`, `import_validation_failed`.

#### Scenario: Developer handles errors uniformly across transports
- **WHEN** a developer reads the error code catalog
- **THEN** they can write a single error-handling switch that covers Elixir tuples, CLI stderr, MCP error responses, and WebSocket error events