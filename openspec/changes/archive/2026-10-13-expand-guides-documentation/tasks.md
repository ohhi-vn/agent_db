# Tasks

## 1. Repair the `da5adc6` rename fallout (docs/ -> guides/)

- [x] 1.1 Update `mix.exs`: point the docs `extras` at the `guides/` set (QUICKSTART, SETUP, USAGE, agents.md, ARCHITECTURE, MONITORING, and the guides added by this change), and change the package `files` entry from `docs` to `guides`. Verify: `mix docs` exits 0 with no `warning:` lines in the log (the CI gate in `.github/workflows/verify.yml`), and `mix hex.build` succeeds.
- [x] 2 Update `tools/verify_package.exs` so `@required` names `guides` instead of `docs`. Verify: `mix run --no-start tools/verify_package.exs` prints "package ok" against the tarball from 1.1.
- [x] 3 Update installer closing messages: `tools/install.sh` ("See docs/agents.md") and `tools/install.ps1` ("see docs/agents.md") point at `guides/agents.md`. Verify: `tools/install.sh --check` completes and its closing message names the guides path.
- [x] 4 Repair link hygiene: `guides/USAGE.md` (5 `docs/` refs), `guides/QUICKSTART.md` (4), `guides/SETUP.md` (1), and the root `README.md` (13 `docs/` links plus inline references) point at `guides/...` (anchors preserved where the link had a fragment, e.g. `docs/SETUP.md#verifying-a-change` -> `guides/SETUP.md#verifying-a-change`). Verify: no `docs/` references remain in guides or README, and `mix docs` reports no broken-link warnings.
- [x] 5 Repair the shipped phantom error catalog: `guides/MONITORING.md`'s failure-classification row lists codes the taxonomy does not emit (`enqueue_failed`, `storage_error`, `provider_unreachable`) and its alert example queries `code="provider_unreachable"`. Replace each with the `AgentDb.Observability` taxonomy's actual codes (`classify_reason/1`, the caller-error tags, `http_status/1`) and the provider health state (`model_status/0` reporting `:unreachable`). Verify: every error code in the guides exists in that taxonomy, every listed MCP tool is in `AgentDbWeb.Mcp.tools/0` (the `USAGE.md`/`agents.md` tables were checked against the 16-tool registry and are accurate), and no alert example queries a code no transport emits.

## 2. Write MONITORING.md catalog repair (spec-side)

- [x] 2.1 Create `guides/MONITORING.md` with `/admin` console walkthrough, telemetry event catalog with attributes, structured log format, health check commands, and alerting thresholds. Verify: file exists and all commands shown are runnable.
- [x] 2.2 Document the shared error code taxonomy with transport mapping table. Verify: **every code listed exists in the `AgentDb.Observability` taxonomy** (the runtime-observability spec mandates the shared taxonomy and does not enumerate codes, so the code module is the catalog's source).
- [x] 2.3 Verify all CLI commands (`mix agent_db.doctor --json`, `AgentDb.health_check()`, `AgentDb.queue_stats()`) produce the JSON shapes documented. Verify: running each command matches the documented output structure.

## 3. Write API-REFERENCE.md

- [x] 3.1 Create `guides/API-REFERENCE.md` with its Elixir section mapping each public entry point of the `AgentDb` module (`lib/agent_db/agent_db.ex`) to the generated documentation (hexdocs for the released version; `mix docs` locally), organised by domain with a link per entry point, **without hand-copying signatures, option tables, or return shapes**. Verify: no function signature is hand-copied in the guide (grep for `def ` patterns of the module's functions), every domain group in `mix docs` (the `groups_for_modules` families) is reachable from the mapping, and the local `mix docs` build has every public function documented.
- [x] 3.2 Document all `mix agent_db.*` CLI tasks from `lib/mix/tasks/` (doctor, read, search, find, grep, tree, recall, index, import_skills, import_data, export_data, seed) with each task's `@switches` (including `--no-compile` where declared), the human-readable and JSON output shapes, and exit codes. Verify: the task list matches the directory exactly and each document switch exists in that task's `@switches`.
- [x] 3.3 Document all MCP tools from the `AgentDbWeb.Mcp.tools/0` registry in `lib/agent_db_web/mcp.ex` (the eight `context_*` tools, `memory_recall`/`memory_remember`/`memory_forget`, `session_create`/`session_append`/`session_get`/`session_commit`, and `store_health` — 16 tools) with the request schema as declared, success response, and error response (`{code, message}`). Verify: the tool list matches `tools/0` exactly — no tool listed that the registry does not define, no registry tool left undocumented; the `context_search` entry shows the flat schema (`term`, optional `mode`, `scope`, `top_k`), not an `opts` wrapper.
- [x] 3.4 Document all WebSocket events handled in `lib/agent_db_web/channel.ex` (`v1.write`, `v1.read`, `v1.abstract`, `v1.overview`, `v1.list`, `v1.tree`, `v1.rm`, `v1.search`, `v1.find`, `v1.grep`, `v1.remember`, `v1.recall`, `v1.forget`, `v1.create_session`, `v1.get_session`, `v1.model_status`, `v1.health`, `v1.subscribe`, `v1.unsubscribe`, `v1.search_progress`) with payload/response/error schemas, labelling pushed-only `v1.append_message`/`v1.commit_session` as responses and `v1.context_changed` as the subscription push, and document subscription semantics (per-connection, lost on reconnect). Verify: event list matches the channel's `handle_in` clauses exactly; `traceparent` is documented only for the MCP HTTP controller, where the code implements it, and the guide claims no propagation rule the channel does not implement.
- [x] 3.5 Create the unified error code catalog table mapping every code from the `AgentDb.Observability` taxonomy (`classify_reason/1`, the caller-error tags, and the `http_status/1` classification) to its HTTP-style status, the transports where it appears, and a one-line description. Verify: every row exists in the taxonomy and is reachable from at least one transport; no invented code appears (the earlier draft's `provider_unreachable`, `queue_backpressure`, `enqueue_failed`, `storage_error`, `auth_required`, `skill_refused`, `import_validation_failed` have no emitter in `lib/` and are absent unless a transport gains them).

## 4. Write TROUBLESHOOTING.md

- [x] 4.1 Create `guides/TROUBLESHOOTING.md` with symptom index, diagnostic sections for each symptom (model loading, queue backpressure, inference latency, auth, WSL2, admin console, export/import), and diagnostic commands with expected healthy/unhealthy output. Verify: each diagnostic command runs and produces parseable output.
- [x] 4.2 Document log interpretation patterns for common failure modes with log field mappings. Verify: log field names match the structured log output from the codebase (`component`, `operation`, `outcome`, `code`, `trace_id`).
- [x] 4.3 Verify WSL2 workflow commands (`wsl bash tools/install.sh --check`, `wsl bash -c "curl localhost:6060/api/v1/health"`) work as documented. Verify: commands execute without error in a WSL2 environment (or document expected behavior if WSL2 not available).

## 5. Write guides/README.md (Guide Index)

- [x] 5.1 Create `guides/README.md` with a table listing all guides (QUICKSTART, SETUP, USAGE, ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, agents.md) with one-line audience/purpose description and links. Verify: all links resolve to existing files.
- [x] 5.2 Keep the root `README.md`'s Guides section pointing at `guides/...` (repaired in task 1.4) and linking `guides/README.md` as the guide index. Verify: root README renders with working links.

## 6. Update usage-guides spec

- [x] 6.1 Apply the delta spec at `openspec/changes/expand-guides-documentation/specs/usage-guides/spec.md` to the main spec at `openspec/specs/usage-guides/spec.md`. Verify: `openspec validate` passes on the updated spec.
- [x] 6.2 Verify the updated spec's discovery and verification requirements cover all eight guides and point only at `guides/` paths (the delta restores the paths the `da5adc6` rename left stale in the quickstart, setup, and usage requirements). Verify: spec text explicitly names ARCHITECTURE, MONITORING, API-REFERENCE, TROUBLESHOOTING, and guides/README.md, and contains no remaining `docs/` path references.

## 7. Full Verification

- [x] 7.1 Run `mix docs` and verify no broken links in generated documentation and that every guide (including the three added by this change) appears as an extra. Verify: `mix docs` exits 0 with no `warning:` lines — the CI gate.
- [x] 7.2 Run `tools/install.sh --check` and `mix agent_db.doctor` to verify all CLI and daemon snippets in all guides work. Verify: both commands pass.
- [x] 7.3 Run `mix hex.build` then `mix run --no-start tools/verify_package.exs`. Verify: the built package contains `guides` and the verification prints "package ok".
- [x] 7.4 Run `openspec validate` on the change. Verify: validation passes with no errors.

## Workflow follow-up

- Archive the change after the project's review requirements are satisfied.
- Verify the archived result.
