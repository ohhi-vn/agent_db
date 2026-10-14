# Spec Delta

## MODIFIED Requirements

### Requirement: Short quickstart guide
The system SHALL provide `guides/QUICKSTART.md` that takes a new user from prerequisites to first verified write, read, search, and health check in under five minutes of reading, ending with links to the full setup and usage guides.

#### Scenario: New user follows quickstart
- **WHEN** a new user with Elixir installed follows `guides/QUICKSTART.md` step by step
- **THEN** they start the daemon, write and read back one document, run one search, run the health check successfully, and know which guide to open next

#### Scenario: Quickstart stays short
- **WHEN** a reviewer opens `guides/QUICKSTART.md`
- **THEN** it contains only prerequisites, install, start, first write/read/search, verify, and next-steps links with no full configuration tables or API reference duplicated inside

### Requirement: Full setup guide
The system SHALL provide `guides/SETUP.md` covering prerequisites (Elixir 1.20+, SQLite, EXLA), data and model directories, every `AGENT_DB_*` environment variable, HTTP listener address and port, optional Bearer auth, Apple Silicon backend selection, model pre-placement and truncated-cache recovery, WSL2 notes, and verification via `tools/install.sh --check`, the `mix docs` build, and the doctor task including what to do when each fails.

#### Scenario: Operator configures a deployment
- **WHEN** an operator follows `guides/SETUP.md` to configure directories, environment, listener, and auth
- **THEN** every setting they need is named with its default and failure recovery, and the verification commands confirm readiness or name the missing prerequisite

#### Scenario: Setup matches runtime config
- **WHEN** a reviewer compares `guides/SETUP.md` against the runtime configuration and installer scripts
- **THEN** every documented variable and default matches the runtime source and no documented flag is missing or renamed

### Requirement: Full usage guide
The system SHALL provide `guides/USAGE.md` covering documents and layered summaries, `find` and `grep` navigation, keyword/vector/hybrid search, memory remember/recall/forget, sessions and commit, skills import, data export/import, the `mix agent_db.*` CLI with `--json`, MCP tools for OpenCode and Zed, WebSocket `v1.*` events, the `/admin` console, and the loopback trust boundary. **The system SHALL ALSO provide `guides/ARCHITECTURE.md`, `guides/MONITORING.md`, `guides/API-REFERENCE.md`, `guides/TROUBLESHOOTING.md`, and `guides/README.md` as part of the complete guide set.**

#### Scenario: User completes core workflows from usage guide
- **WHEN** a user follows `guides/USAGE.md` for documents, search, memory, sessions, and skills
- **THEN** each workflow shows copy-paste commands with expected shapes and error meanings sufficient to complete the workflow without opening source code

#### Scenario: Agent integrations stay consistent
- **WHEN** a reviewer compares the MCP, CLI, and WebSocket sections of `guides/USAGE.md` against `guides/agents.md`, the CLI tasks in `lib/mix/tasks/`, and the MCP tool registry
- **THEN** tool names, event names, option names, and editor snippets agree — including that the MCP tool list matches `AgentDbWeb.Mcp.tools/0` exactly, with no tool listed that the registry does not define and no registry tool left undocumented — and any intentional difference is called out

#### Scenario: New guides are discoverable from the guide index
- **WHEN** a user opens `guides/README.md`
- **THEN** they find links to QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, and agents.md with a one-line description of each guide's audience and purpose

### Requirement: Guides are discoverable and verified
The system SHALL link all guides from `README.md` (through the guide index `guides/README.md`), keep the root `README.md` as a short pointer rather than duplicating setup and usage content, and SHALL verify every command and snippet in **all guides** (QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, agents.md) against the public facade and CLI tasks during review so no guide ships with a command that fails as written.

#### Scenario: Entry from README
- **WHEN** a user opens `README.md`
- **THEN** they find links to the quickstart, setup, usage, architecture, monitoring, API reference, troubleshooting, and agent setup guides within the first two screens and no conflicting duplicate instructions

#### Scenario: Snippet verification
- **WHEN** a reviewer runs every shell and Elixir snippet from **all guides** in order
- **THEN** each command succeeds as written or its documented failure recovery resolves it, and any drift from code is fixed before the change is accepted

#### Scenario: Generated documentation builds as a gate
- **WHEN** the reviewer runs `mix docs` (the command CI runs as its documentation gate)
- **THEN** it succeeds with every guide present as an extra and produces no broken-link warnings, and `tools/verify_package.exs` confirms the Hex package contains the guides directory
