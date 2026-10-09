# Spec Delta

## MODIFIED Requirements

### Requirement: Full usage guide
The system SHALL provide `docs/USAGE.md` covering documents and layered summaries, `find` and `grep` navigation, keyword/vector/hybrid search, memory remember/recall/forget, sessions and commit, skills import, data export/import, the `mix agent_db.*` CLI with `--json`, MCP tools for OpenCode and Zed, WebSocket `v1.*` events, the `/admin` console, and the loopback trust boundary. **The system SHALL ALSO provide `guides/ARCHITECTURE.md`, `guides/MONITORING.md`, `guides/API-REFERENCE.md`, `guides/TROUBLESHOOTING.md`, and `guides/README.md` as part of the complete guide set.**

#### Scenario: User completes core workflows from usage guide
- **WHEN** a user follows `docs/USAGE.md` for documents, search, memory, sessions, and skills
- **THEN** each workflow shows copy-paste commands with expected shapes and error meanings sufficient to complete the workflow without opening source code

#### Scenario: Agent integrations stay consistent
- **WHEN** a reviewer compares the MCP, CLI, and WebSocket sections of `docs/USAGE.md` against `docs/agents.md` and the CLI tasks
- **THEN** tool names, event names, option names, and editor snippets agree and any intentional difference is called out

#### Scenario: New guides are discoverable from the guide index
- **WHEN** a user opens `guides/README.md`
- **THEN** they find links to QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, and agents.md with a one-line description of each guide's audience and purpose

### Requirement: Guides are discoverable and verified
The system SHALL link all guides from `README.md`, keep `README.md` as an index with a short pointer instead of duplicating setup and usage content, and SHALL verify every command and snippet in **all guides** (QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, agents.md) against the public facade and CLI tasks during review so no guide ships with a command that fails as written.

#### Scenario: Entry from README
- **WHEN** a user opens `README.md`
- **THEN** they find links to the quickstart, setup, usage, architecture, monitoring, API reference, troubleshooting, and agent setup guides within the first two screens and no conflicting duplicate instructions

#### Scenario: Snippet verification
- **WHEN** a reviewer runs every shell and Elixir snippet from **all guides** in order
- **THEN** each command succeeds as written or its documented failure recovery resolves it, and any drift from code is fixed before the change is accepted