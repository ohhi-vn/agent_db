# Tasks

## 1. Write ARCHITECTURE.md

- [x] 1.1 Create `guides/ARCHITECTURE.md` with component overview, data flow diagrams (Mermaid), deployment topology, and spec/code cross-references. Verify: file exists and renders in GitHub with diagrams visible.
- [x] 1.2 Verify all cross-reference links to specs (`openspec/specs/...`) and code modules (`AgentDb.JobQueue`, `AgentDb.Inference`, etc.) resolve correctly. Verify: no broken links when clicking in GitHub UI.
- [x] 1.3 Validate all shell and Elixir snippets in ARCHITECTURE.md against the public facade. Verify: `mix agent_db.doctor` and `AgentDb.model_status/0` calls produce expected output shapes when run.

## 2. Write MONITORING.md

- [x] 2.1 Create `guides/MONITORING.md` with `/admin` console walkthrough, telemetry event catalog with attributes, structured log format, health check commands, and alerting thresholds. Verify: file exists and all commands shown are runnable.
- [x] 2.2 Document the shared error code taxonomy with transport mapping table. Verify: every code listed appears in runtime-observability spec and admin-dashboard spec.
- [x] 2.3 Verify all CLI commands (`mix agent_db.doctor --json`, `AgentDb.health_check()`, `AgentDb.queue_stats()`) produce the JSON shapes documented. Verify: running each command matches the documented output structure.

## 3. Write API-REFERENCE.md

- [ ] 3.1 Create `guides/API-REFERENCE.md` with complete Elixir `AgentDb` module catalog (all 30+ functions with signatures, options, return shapes, error tuples). Verify: every public function in `lib/agent_db.ex` is documented.
- [ ] 3.2 Document all `mix agent_db.*` CLI tasks with flags, JSON output shapes, and exit codes. Verify: `mix help agent_db.<task>` output matches documented flags for each task.
- [ ] 3.3 Document all MCP tools with request/response/error JSON schemas. Verify: schemas match the MCP tool implementations in `lib/agent_db/mcp/`.
- [ ] 3.4 Document all WebSocket `v1.*` events with payload/response/error schemas and `traceparent` rules. Verify: event names match `lib/agent_db/web_socket/` handlers.
- [ ] 3.5 Create unified error code catalog table mapping codes across all four transports. Verify: every code in the table is emitted by at least one transport and listed in the runtime-observability spec.

## 4. Write TROUBLESHOOTING.md

- [ ] 4.1 Create `guides/TROUBLESHOOTING.md` with symptom index, diagnostic sections for each symptom (model loading, queue backpressure, inference latency, auth, WSL2, admin console, export/import), and diagnostic commands with expected healthy/unhealthy output. Verify: each diagnostic command runs and produces parseable output.
- [ ] 4.2 Document log interpretation patterns for common failure modes with log field mappings. Verify: log field names match the structured log output from the codebase (`component`, `operation`, `outcome`, `code`, `trace_id`).
- [ ] 4.3 Verify WSL2 workflow commands (`wsl bash tools/install.sh --check`, `wsl bash -c "curl localhost:6060/api/v1/health"`) work as documented. Verify: commands execute without error in a WSL2 environment (or document expected behavior if WSL2 not available).

## 5. Write guides/README.md (Guide Index)

- [ ] 5.1 Create `guides/README.md` with a table listing all guides (QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, agents.md) with one-line audience/purpose description and links. Verify: all links resolve to existing files.
- [ ] 5.2 Update root `README.md` to link to `guides/README.md` as the primary guide index. Verify: root README renders with working link.

## 6. Update usage-guides spec

- [ ] 6.1 Apply the delta spec at `openspec/changes/expand-guides-documentation/specs/usage-guides/spec.md` to the main spec at `openspec/specs/usage-guides/spec.md`. Verify: `openspec validate` passes on the updated spec.
- [ ] 6.2 Verify the updated spec's discovery and verification requirements cover all eight guides. Verify: spec text explicitly names ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, and guides/README.md.

## 7. Full Verification

- [ ] 7.1 Run `mix docs` and verify no broken links in generated documentation. Verify: `mix docs` exits 0 and `doc/` contains all guide references.
- [ ] 7.2 Run `tools/install.sh --check` and `mix agent_db.doctor` to verify all CLI and daemon snippets in all guides work. Verify: both commands pass.
- [ ] 7.3 Run `openspec validate` on the change. Verify: validation passes with no errors.

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.