# Design

## Context

The project has eight guides in `guides/`: `QUICKSTART.md`, `SETUP.md`, `USAGE.md`, `agents.md`, plus `ARCHITECTURE.md` and `MONITORING.md` from this change, with `API-REFERENCE.md`, `TROUBLESHOOTING.md`, and the index `README.md` still to write. The `usage-guides` spec mandates the three core guides plus agent setup, with verification requirements; this change extends that set to all eight guides and the index.

Commit `da5adc6` renamed `docs/` to `guides/` as pure renames, and every system naming the docs directory went stale at that moment: the `mix.exs` extras list and package file list, `tools/verify_package.exs`'s `@required`, both installer scripts' closing messages, 13 README links, and 10 cross-references inside `USAGE.md`/`QUICKSTART.md`/`SETUP.md`. The `usage-guides` spec of record still asserts `docs/` paths. The `mix docs` build — which is also the CI documentation gate — currently crashes on the stale extras. The rename repair is therefore this change's prerequisite, not a separate concern.

The same investigation found the existing catalogs drifting: `MONITORING.md` lists error codes no transport emits and shows an alert query on one; and this change's own delta specs enumerate function and WebSocket-event lists that disagree with `lib/` (verified against the code: the facade has 51 public entry points vs the 30 enumerated, the channel handles 20 events vs 13, and 7 of 13 enumerated error codes have no emitter in `lib/`). The MCP tool tables in `USAGE.md` and `agents.md` were verified accurate against the 16-tool registry and are left untouched.

All new guides are pure Markdown documentation. The change adds no new dependencies, migrations, or runtime behavior; what it does edit outside `guides/` is build and packaging configuration and installer strings — the rename repair.

## Goals / Non-Goals

**Goals:**

- Repair the `da5adc6` rename fallout so `mix docs`, the package check, and every link an reader can click resolve, with the CI gates as the enforcement
- Repair the phantom error catalogs already shipped in `MONITORING.md` against the `AgentDb.Observability` taxonomy
- Create `guides/ARCHITECTURE.md`, `guides/MONITORING.md`, `guides/API-REFERENCE.md`, `guides/TROUBLESHOOTING.md`, and the `guides/README.md` index
- Shape `guides/API-REFERENCE.md` so it cannot silently drift: the Elixir API points into the generated documentation, the three transports are documented by hand each with a named code source, and the error catalog is the `AgentDb.Observability` taxonomy
- Update `openspec/specs/usage-guides/spec.md` to require the full guide set and to point at `guides/`

**Non-Goals:**

- No changes to runtime code, actions, or data models
- No new CLI tasks, API endpoints, or MCP tools
- No changes to the `/admin` console implementation
- No hand-copied Elixir function signatures in the guides (the generated docs own that surface)
- No automated catalog-check tooling (a docs-test asserting guide catalogs against code sources) — deferred to a future change, since it requires code
- No translation or localization
- No video or interactive content

## Decisions

### 1. Guide structure follows existing conventions
**Decision**: New guides follow the same Markdown style as existing guides (concise, example-heavy, cross-referenced). Use the same heading levels, code fence conventions, and URI scheme (`viking://`).

**Rationale**: Consistency reduces cognitive load. The existing guides are well-received; matching their voice and structure makes the new guides feel like a natural extension.

**Alternatives considered**: 
- Structured reference format (like man pages) for API-REFERENCE — rejected because the existing USAGE.md blends reference and workflow successfully, and users expect the same style.
- Separate `docs/` vs `guides/` directories — rejected; see decision 6.

### 2. ARCHITECTURE.md uses text diagrams, not images
**Decision**: Use Mermaid.js-compatible text diagrams (renderable in GitHub/GitLab) for component and data flow diagrams. No binary images.

**Rationale**: Text diagrams are version-controllable, diffable, and render in the repo UI. No build step or asset pipeline needed.

**Alternatives considered**:
- PlantUML — requires Java tooling; Mermaid is more widely rendered natively.
- Externally hosted images — adds maintenance burden and breaks offline reading.

### 3. MONITORING.md focuses on actionable operator workflows
**Decision**: Structure around operator tasks ("Check health", "Diagnose backlog", "Set up alerts") rather than telemetry event catalogs. Include exact commands and expected JSON shapes.

**Rationale**: Operators need task-oriented guidance, not raw event schemas. The runtime-observability spec already documents the events; this guide bridges to operational practice.

**Alternatives considered**:
- Pure event catalog — too low-level; belongs in API-REFERENCE or spec.
- Grafana dashboard JSON export — out of scope; operators use diverse stacks.

### 4. API-REFERENCE.md is shaped by what has a generated surface
**Decision**: Each surface of the reference takes the form that cannot drift:
- **Elixir module API** — maps entry points to their generated documentation (hexdocs, or `mix docs` locally); signatures, options, and return shapes are never hand-copied.
- **CLI, MCP, WebSocket** — documented by hand, because nothing generates them, each with its code source of truth named (`lib/mix/tasks/` and its `@switches`, `AgentDbWeb.Mcp.tools/0`, `lib/agent_db_web/channel.ex`), so future drift is checkable instead of invisible.
- **Error catalog** — the `AgentDb.Observability` taxonomy (`classify_reason/1`, caller-error tags, `http_status/1`) mapped across transports; codes no transport emits may not appear.

Enumeration is replaced by named sources plus a verification duty: requirements say "every task in `lib/mix/tasks/`" rather than listing twelve names, because the list was verified wrong in all five categories during exploration.

**Rationale**: The root README's stated stance is that the API reference is generated from the code and cannot drift. The exploration found the frozen enumerations already wrong: the facade has 51 public entry points against the 30 the draft enumerated (with wrong arities — `search/2`, not `search/3`), and the channel handles 20 events against 13. A hand-written module catalog would start stale on arrival; hand-written transports with named sources are the correct shape precisely because their absence of a generator makes a source reference checkable by review.

**Alternatives considered**:
- Hand-written complete Elixir catalog (the change's original shape) — rejected: verified stale before writing; contradicts the README's generated-docs stance.
- Generate the CLI/MCP/WS catalogs from code — right long-term answer, but a docs-test is code; the change's non-goal is no code changes, so deferred to a future change.
- Drop the hand-written transports entirely — rejected: they have no generated surface and their absence is the gap the guide exists to fill.

### 5. TROUBLESHOOTING.md is symptom-indexed, not component-indexed
**Decision**: Top-level index by observable symptom ("Search returns model_loading", "Queue grows") not by component ("ModelManager issues", "JobQueue issues").

**Rationale**: Operators observe symptoms, not component names. Component-indexed guides require knowing the architecture first.

**Alternatives considered**:
- Component-indexed with symptom cross-reference — adds indirection; symptom-first is faster in incident response.

### 6. Guides live in `guides/`; the rename fallout is repaired, not reverted
**Decision**: All guides live in `guides/`, and every stale reference to `docs/` is repaired across `mix.exs`, `tools/verify_package.exs`, both installer scripts, `README.md`, the guides' own cross-references, and the `usage-guides` spec. The rename is not reverted.

**Rationale**: The rename is committed, and the root README already presents the section as "Guides". The repair's blast radius was verified as exactly eight surfaces, and the repair makes two existing gates — the `mix docs` CI gate and the package check — into permanent enforcement, which is the project's stated "one definition of each gate" discipline.

**Alternatives considered**:
- Rename `guides/` back to `docs/` — one move instead of eight repairs, but reverts a committed decision and buys nothing.
- Keep both (symlink `docs` → `guides`) — rejected: symlinks in Hex packages and across Windows/WSL2 environments are a documented hazard for this project.

## Risks / Trade-offs

- **[Risk] Hand-written transport catalogs drift** → **Mitigation**: each section names its code source, requirements say "every X in the directory/registry/handler file," and review compares against those sources; a future docs-test can automate the comparison.
- **[Risk] Generated-docs link targets move with releases** → **Mitigation**: the guide links the versioned hexdocs and documents the local `mix docs` alternative, so a local build always resolves.
- **[Risk] Guide sprawl** → **Mitigation**: `guides/README.md` is the single entry point; the usage-guides spec mandates verification of all guides.
- **[Risk] Phantom catalogs return** → **Mitigation**: the shipped case (MONITORING's error row and alert query) is repaired against the taxonomy, and the catalog requirement forbids codes no transport emits.
- **[Risk] Mermaid diagrams not rendered in all viewers** → **Mitigation**: Diagrams are readable as plain text. GitHub/GitLab/VS Code render them; other viewers show readable source.
- **[Risk] Duplicate content between USAGE.md and API-REFERENCE.md** → **Mitigation**: USAGE.md stays workflow-oriented (how to accomplish tasks); API-REFERENCE.md is a catalog with links to generated docs, cross-linking instead of duplicating.
- **[Risk] TROUBLESHOOTING.md becomes a dumping ground for edge cases** → **Mitigation**: Only include issues with verified resolutions and diagnostic commands; speculative entries fail the spec's verification requirement.

## Migration Plan

1. Repair the rename fallout first (mix.exs extras + package list, verify_package.exs, installers, README and guide links) so the `mix docs` and package gates pass before new content is written
2. Repair the phantom error catalog already shipped in `MONITORING.md` against the `AgentDb.Observability` taxonomy
3. Write `API-REFERENCE.md` and `TROUBLESHOOTING.md` against the named code sources, and create the `guides/README.md` index
4. Apply the delta specs to `openspec/specs/usage-guides/spec.md` (the full guide set and restored `guides/` paths)
5. Run `mix docs` (no warnings) and `mix run --no-start tools/verify_package.exs` as the closing gates; `tools/install.sh --check` re-verifies installer behavior
6. No deployment steps needed

**Rollback**: Delete the three new guides, revert the spec deltas, and revert the eight repaired surfaces. No data migration or code rollback is needed — the change edits no runtime code.

## Open Questions

- Should catalog verification be automated (a docs-test that extracts `tools/0`, the channel's `handle_in` events, the task switches, and the Observability taxonomy and asserts the guide matches)? Deferred: it requires code, and this change's non-goal is no code changes. The guide's named-source discipline keeps the manual check cheap.
