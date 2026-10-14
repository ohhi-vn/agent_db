# agent-tooling Specification

## Purpose
Lets OpenCode and Zed agents use the shared AgentDb daemon through remote MCP tools with a machine-readable CLI fallback and copy-paste setup that verifies itself.

## Requirements

### Requirement: MCP tool inventory for full read-write store access
The system SHALL expose the full store facade as MCP tools over the remote endpoint: `context_read`, `context_write`, `context_rm`, `context_list`, `context_tree`, `context_search`, `context_find`, `context_grep`, `memory_recall`, `memory_remember`, `memory_forget`, `session_create`, `session_append`, `session_get`, `session_commit`, and `store_health`. Each tool SHALL accept the same option names as the facade (`mode`, `scope`, `top_k`, `limit`, `confidence`, `source`). Errors SHALL be JSON strings or maps and SHALL NOT terminate the session. A call deferred only because a model is still loading SHALL return distinguishable `model_loading` so the client retries rather than concluding the capability is unavailable.

**The inventory SHALL ALSO include the layer read tools `context_abstract`, `context_overview`, and `context_layers`, so an LLM client can reach a document's L0 and L1 layers rather than only its L2 content.** `context_abstract` SHALL accept `uri` and return the document's abstract, `context_overview` SHALL accept `uri` and return the document's overview, and `context_layers` SHALL accept `uri` and return all three layers in one call, each with the text, whether the layer was stored or fallback-derived, and its character count. A layer whose read fails SHALL be reported as unavailable within the same response rather than failing the whole call. These tools SHALL accept the same option names as the facade, and `context_search` SHALL accept the facade's `fields` option under the same name.

#### Scenario: Agent lists tools and reads a document
- **WHEN** a client sends `initialize` then `tools/list`
- **THEN** the response lists `context_read` and `context_search` among the inventory
- **AND** a subsequent `tools/call context_read` with a stored URI returns its content

#### Scenario: Agent searches with modes and scopes
- **WHEN** a client calls `context_search` with `mode hybrid` and a subtree `scope`
- **THEN** ranked results return with URIs
- **AND** `context_find` and `context_grep` preserve literal matching, scoping, ordering, and limits

#### Scenario: Agent reads a document's layers before its content
- **WHEN** a client calls `context_layers` with a stored URI
- **THEN** the response carries L0, L1, and L2 as separate entries
- **AND** each entry carries its text, whether it was stored or fallback-derived, and its character count
- **AND** the client can decide from L0 and L1 alone whether to read L2

#### Scenario: One unavailable layer does not fail the others
- **WHEN** a client calls `context_layers` on a stored document whose abstract read fails
- **THEN** the abstract entry is reported as unavailable
- **AND** the L1 and L2 entries still return their text, source, and character count

#### Scenario: Agent asks for a short search result
- **WHEN** a client calls `context_search` with `fields` naming `uri`, `abstract`, and `score`
- **THEN** each result carries only those fields
- **AND** no result carries its document content

#### Scenario: Layer tools answer without a model
- **WHEN** a client calls `context_abstract` on a document whose abstract was caller-supplied
- **THEN** the call returns that abstract
- **AND** the call does not depend on any model being loaded

#### Scenario: Unservable MCP call returns error without breaking session
- **WHEN** a client calls a tool requiring an unavailable model
- **THEN** the response is a JSON-RPC error naming the reason
- **AND** the session stays usable for subsequent calls

#### Scenario: Deferred model load is distinguishable
- **WHEN** a client calls a tool needing a model that is still loading
- **THEN** the error identifies `model_loading`
- **AND** the client can tell it apart from a failure

### Requirement: Machine-readable CLI fallback
The system SHALL provide `mix agent_db.read`, `mix agent_db.find`, `mix agent_db.grep`, and `mix agent_db.recall` in addition to the existing `search`, `tree`, `index`, `import_skills`, and `doctor` tasks. Every CLI task SHALL support `--json`, which prints the result as JSON to stdout. Without `--json` the existing human text output SHALL remain unchanged. Failures SHALL exit non-zero with the reason on stderr.

**The CLI SHALL ALSO provide `mix agent_db.abstract` and `mix agent_db.overview`, each accepting a URI and supporting `--json`, so a shell-driven agent can read a single layer without a full document read.**

#### Scenario: Agent reads a document as JSON from shell
- **WHEN** an agent runs `mix agent_db.read viking://resources/foo.md --json`
- **THEN** stdout contains the content as JSON
- **AND** a missing document exits non-zero

#### Scenario: Agent reads a layer as JSON from shell
- **WHEN** an agent runs `mix agent_db.abstract viking://resources/foo.md --json`
- **THEN** stdout contains the abstract as JSON
- **AND** `mix agent_db.overview` on the same URI returns its overview
- **AND** a missing document exits non-zero with the reason on stderr

#### Scenario: Agent discovers paths and recalls memory as JSON
- **WHEN** an agent runs `mix agent_db.find TERM --json` and `mix agent_db.recall --type preferences --json`
- **THEN** each prints a JSON array usable without text parsing
- **AND** running without `--json` preserves the current human-readable lines

### Requirement: Install via external tools with print-only editor snippets
The system SHALL provide `tools/install.sh` for macOS and Linux (including WSL2) that uses external package managers for prerequisites and fetches models, plus `tools/install.ps1` for Windows that checks for WSL and delegates to `install.sh`. The installer SHALL print ready-to-paste OpenCode (`mcp.servers` remote) and Zed (`context_servers` remote) snippets pointing at the configured daemon URL and SHALL verify daemon reachability plus required files. It SHALL NOT edit editor configs in place and SHALL leave existing editor settings untouched. A missing prerequisite or unreachable daemon SHALL fail with an actionable message.

#### Scenario: Fresh machine with missing Elixir fails helpfully
- **WHEN** the installer runs without Elixir 1.20+ present
- **THEN** it exits non-zero naming the required external tool and install command
- **AND** no editor file is created or modified

#### Scenario: Successful install prints snippets and verifies daemon
- **WHEN** prerequisites exist and the daemon answers on the configured port
- **THEN** the installer prints both editor snippets
- **AND** reports daemon reachability and required files as verified

### Requirement: Editor setup snippets for OpenCode and Zed
The system SHALL document a default no-auth remote snippet (`http://127.0.0.1:6060/mcp`) and a Bearer opt-in variant using `AGENT_DB_HTTP_AUTH` tokens as headers. The OpenCode snippet SHALL use `mcp.servers` with `command` as an array for local or `url` for remote; the Zed snippet SHALL use `context_servers` with `command` as a string plus `args` for local or `url` for remote. The guide SHALL call out that the two editors differ in `command` shape so one snippet cannot serve both verbatim.

#### Scenario: Default snippet connects without auth
- **WHEN** an operator pastes the default snippet with the daemon on loopback and no auth configured
- **THEN** `tools/list` succeeds from both editors

#### Scenario: Bearer opt-in snippet connects with token
- **WHEN** an operator enables Bearer auth and pastes the token variant with `Authorization` headers
- **THEN** authenticated `tools/call` succeeds
- **AND** requests without the token are rejected
