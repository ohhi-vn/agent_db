# Spec Delta

## MODIFIED Requirements

### Requirement: Full usage guide
The system SHALL provide `guides/USAGE.md` covering documents and layered summaries, `find` and `grep` navigation, keyword/vector/hybrid search, memory remember/recall/forget, sessions and commit, skills import, data export/import, the `mix agent_db.*` CLI with `--json`, MCP tools for OpenCode and Zed, WebSocket `v1.*` events, the `/admin` console, and the loopback trust boundary. **The system SHALL ALSO provide `guides/ARCHITECTURE.md`, `guides/MONITORING.md`, `guides/API-REFERENCE.md`, `guides/TROUBLESHOOTING.md`, and `guides/README.md` as part of the complete guide set.**

**USAGE.md SHALL ALSO document the layer-first read path for LLM clients: reading L0 then L1 before L2, the `context_abstract`, `context_overview`, and `context_layers` MCP tools and the `mix agent_db.abstract` and `mix agent_db.overview` CLI tasks, the `fields` search option for asking a search to answer with URIs and abstracts only, and the fact that a fallback layer is derived from L2 and says so.**

#### Scenario: User completes core workflows from usage guide
- **WHEN** a user follows `guides/USAGE.md` for documents, search, memory, sessions, and skills
- **THEN** each workflow shows copy-paste commands with expected shapes and error meanings sufficient to complete the workflow without opening source code

#### Scenario: Agent integrations stay consistent
- **WHEN** a reviewer compares the MCP, CLI, and WebSocket sections of `guides/USAGE.md` against `guides/agents.md`, the CLI tasks in `lib/mix/tasks/`, and the MCP tool registry
- **THEN** tool names, event names, option names, and editor snippets agree — including that the MCP tool list matches `AgentDbWeb.Mcp.tools/0` exactly, with no tool listed that the registry does not define and no registry tool left undocumented — and any intentional difference is called out

#### Scenario: Layer-first path is documented for agent clients
- **WHEN** a reviewer reads the layer section of `guides/USAGE.md`
- **THEN** it shows the read-L0-then-L1-before-L2 path with the exact tool and CLI names that serve it
- **AND** it shows the `fields` option returning URIs and abstracts only
- **AND** it states that a fallback layer is derived from L2 and how a caller can tell

#### Scenario: New guides are discoverable from the guide index
- **WHEN** a user opens `guides/README.md`
- **THEN** they find links to QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, and agents.md with a one-line description of each guide's audience and purpose
