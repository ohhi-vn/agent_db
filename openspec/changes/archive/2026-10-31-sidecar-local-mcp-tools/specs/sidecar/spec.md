# sidecar Specification

## Purpose
Lets a host Elixir application embed AgentDb as a sidecar in its own BEAM VM and invoke AgentDb's MCP tool inventory directly in-process, without an HTTP round-trip or the Phoenix web layer, while preserving the remote MCP/HTTP contract unchanged.

## ADDED Requirements

### Requirement: Sidecar embedding starts the store without a listener by default
The system SHALL be usable as an embedded sidecar in a host Elixir application. Starting the `:agent_db` application (via `Application.ensure_all_started/1` or as part of the host's supervision tree) SHALL start the store's supervision tree, including storage, cache, workers, and PubSub. When `http_enabled` is false, the system SHALL start successfully with no HTTP listener bound, while still providing the full `AgentDb` facade and the local tool inventory. Configuration keys (`data_dir`, `db_path`, `model_cache_dir`, `http_enabled`, `http_auth`, `inference_provider`, and related settings) SHALL be readable at call time so a host can configure them before or after boot.

#### Scenario: Sidecar boots with HTTP disabled
- **WHEN** a host application starts `:agent_db` with `http_enabled: false`
- **THEN** the store's supervision tree starts
- **AND** no network listener is bound
- **AND** `AgentDb.write/3` and `AgentDb.read/1` succeed against the configured data directory

#### Scenario: Sidecar boots with HTTP enabled
- **WHEN** a host application starts `:agent_db` with `http_enabled: true`
- **THEN** the store's supervision tree starts
- **AND** the HTTP listener is bound on the configured interface and port
- **AND** the local tool inventory remains available in-process

### Requirement: Web-independent local tool inventory
The system SHALL expose the full MCP tool inventory through a core module that does not require the Phoenix web layer or an HTTP listener. The inventory SHALL include every tool served by the remote endpoint (`context_read`, `context_abstract`, `context_overview`, `context_layers`, `context_write`, `context_rm`, `context_list`, `context_tree`, `context_search`, `context_find`, `context_grep`, `memory_recall`, `memory_remember`, `memory_forget`, `memory_candidates`, `memory_promote`, `memory_reject`, `session_create`, `session_append`, `session_get`, `session_commit`, `store_health`) with identical names, descriptions, and input schemas. The inventory SHALL be obtainable without a network connection or a booted HTTP endpoint.

#### Scenario: Host lists tools in-process
- **WHEN** a host application calls the core module's `tools/0`
- **THEN** the returned list contains every remote tool name
- **AND** each entry carries its `name`, `description`, and `inputSchema`
- **AND** the call does not require an HTTP listener or a network round-trip

### Requirement: Direct in-process tool invocation
The system SHALL provide a function to invoke a tool by name with a map of arguments directly in-process, returning `{:ok, term()}` on success or `{:error, reason}` on failure, without JSON-RPC encoding, HTTP, or a network round-trip. The returned data SHALL match what the remote endpoint returns for the same tool and arguments. A tool deferred only because a model is still loading SHALL return `{:error, :model_loading}` so the caller can distinguish it from a failure. Trace context MAY be passed via options and SHALL be propagated to store operations that accept it.

#### Scenario: Host reads a document via a local tool
- **WHEN** a host application calls the core module's tool invocation with `context_read` and `%{"uri" => uri}` for a stored document
- **THEN** the call returns `{:ok, %{"uri" => uri, "content" => content}}`
- **AND** no JSON-RPC envelope or HTTP request is involved

#### Scenario: Host receives a model-loading error distinctly
- **WHEN** a host application invokes a tool that needs a model that is still loading
- **THEN** the call returns `{:error, :model_loading}`
- **AND** the caller can distinguish it from other failures

#### Scenario: Unknown tool is reported
- **WHEN** a host application invokes a tool name not in the inventory
- **THEN** the call returns `{:error, {:unknown_tool, name}}` (or an equivalent classified error)
- **AND** the store remains usable for subsequent calls

### Requirement: JSON-RPC compatibility preserved
The core module SHALL support JSON-RPC `initialize`, `tools/list`, and `tools/call` via `handle_request/2` with the same response shapes as before, so the HTTP controller and existing clients behave unchanged. The HTTP `POST /mcp` endpoint SHALL continue to authenticate via the `:api` pipeline and extract trace context from the `traceparent` header, delegating dispatch to the core module.

#### Scenario: Remote initialize and tools/list still work
- **WHEN** a remote client sends `initialize` then `tools/list` to `POST /mcp`
- **THEN** the responses match the pre-existing shapes (protocol version, server info, full tool list)

#### Scenario: Remote tools/call dispatches through core
- **WHEN** a remote client calls `tools/call` with a valid tool name and arguments
- **THEN** the result is produced by the same dispatch logic as the local invocation path

### Requirement: Single source of dispatch
Tool dispatch logic (name-to-facade mapping, argument validation, option translation, trace propagation) SHALL be defined once, in the core module. The web adapter and HTTP controller SHALL NOT reimplement it; they SHALL delegate to the core module.

#### Scenario: Dispatch is not duplicated
- **WHEN** the tool dispatch is inspected
- **THEN** the name-to-facade mapping exists in exactly one module (`AgentDb.Mcp`)
- **AND** `AgentDbWeb.Mcp` (if retained) contains no dispatch logic of its own

### Requirement: Backward-compatible web module
`AgentDbWeb.Mcp` SHALL remain available as a compatibility shim delegating to the core module, so existing callers referencing `AgentDbWeb.Mcp.tools/0`, `AgentDbWeb.Mcp.handle_request/2` continue to work without changes.

#### Scenario: Existing callers keep working
- **WHEN** code calls `AgentDbWeb.Mcp.tools/0` or `AgentDbWeb.Mcp.handle_request/2`
- **THEN** the result is identical to calling the core module's equivalent function