# Design

## Context

The project currently has four guides in `guides/`: `SETUP.md`, `QUICKSTART.md`, `USAGE.md`, and `agents.md`. The `usage-guides` spec (at `openspec/specs/usage-guides/spec.md`) mandates these three core guides plus agent setup, with verification requirements. This change adds four new deep-dive guides and a guide index, extending the existing documentation structure without modifying any runtime behavior.

All new guides are pure Markdown documentation. No code changes, no new dependencies, no schema migrations. The implementation consists of writing five new Markdown files in `guides/` and updating the `usage-guides` spec to require them.

## Goals / Non-Goals

**Goals:**
- Create `guides/ARCHITECTURE.md` with component diagrams, data flow descriptions, and deployment topology
- Create `guides/MONITORING.md` with `/admin` console usage, telemetry integration, log interpretation, and alerting rules
- Create `guides/API-REFERENCE.md` with complete catalogs for Elixir API, CLI, MCP tools, and WebSocket events including error code catalog
- Create `guides/TROUBLESHOOTING.md` with symptom-driven diagnostics, diagnostic commands, and log pattern matching
- Create `guides/README.md` as a guide index with audience and purpose for each guide
- Update `openspec/specs/usage-guides/spec.md` to extend discovery and verification requirements to the new guides

**Non-Goals:**
- No changes to runtime code, configuration, or data models
- No new CLI tasks, API endpoints, or MCP tools
- No changes to the `/admin` console implementation
- No translation or localization
- No video or interactive content

## Decisions

### 1. Guide structure follows existing conventions
**Decision**: New guides follow the same Markdown style as existing guides (concise, example-heavy, cross-referenced). Use the same heading levels, code fence conventions, and URI scheme (`viking://`).

**Rationale**: Consistency reduces cognitive load. The existing guides are well-received; matching their voice and structure makes the new guides feel like a natural extension.

**Alternatives considered**: 
- Structured reference format (like man pages) for API-REFERENCE — rejected because the existing USAGE.md blends reference and workflow successfully, and users expect the same style.
- Separate `docs/` vs `guides/` directories — rejected; the project uses `guides/` (symlinked or referenced as `docs/` in some places) and the spec refers to `docs/`. Keep one location.

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

### 4. API-REFERENCE.md uses a unified error code catalog
**Decision**: Single table mapping error codes across all four transports (Elixir, CLI, MCP, WebSocket) with transport-specific payload shapes shown inline.

**Rationale**: The runtime-observability spec mandates a shared bounded error taxonomy. A unified catalog lets developers write one error-handling switch. Duplicating per-transport would drift.

**Alternatives considered**:
- Per-transport error sections — rejected because the spec requires code consistency across transports.
- Auto-generated from code — no code generation infrastructure exists; manual table is maintainable given the bounded code set.

### 5. TROUBLESHOOTING.md is symptom-indexed, not component-indexed
**Decision**: Top-level index by observable symptom ("Search returns model_loading", "Queue grows") not by component ("ModelManager issues", "JobQueue issues").

**Rationale**: Operators observe symptoms, not component names. Component-indexed guides require knowing the architecture first.

**Alternatives considered**:
- Component-indexed with symptom cross-reference — adds indirection; symptom-first is faster in incident response.

### 6. Guides live in `guides/` and are linked from root `README.md`
**Decision**: Place all guides in `guides/`. Update root `README.md` to link to `guides/README.md` as the guide index.

**Rationale**: Current `QUICKSTART.md` links to `docs/SETUP.md` etc. — the `docs/` prefix appears to be a symlink or convention. Using `guides/` consistently avoids confusion.

**Alternatives considered**:
- Keep `docs/` prefix — would require verifying symlink behavior across environments.

## Risks / Trade-offs

- **[Risk] Guide sprawl** → **Mitigation**: The `guides/README.md` index provides a single entry point. The `usage-guides` spec mandates verification of all guides, preventing orphaned docs.
- **[Risk] API-REFERENCE.md drifts from code** → **Mitigation**: The `usage-guides` spec requires snippet verification during review. Add a CI step (future) to automate checking Elixir snippets against compiled docs.
- **[Risk] Mermaid diagrams not rendered in all viewers** → **Mitigation**: Diagrams are readable as plain text. GitHub/GitLab/VS Code render them; other viewers show readable source.
- **[Risk] Duplicate content between USAGE.md and API-REFERENCE.md** → **Mitigation**: USAGE.md stays workflow-oriented (how to accomplish tasks); API-REFERENCE.md is a complete catalog (all options, all error codes). Cross-link instead of duplicating.
- **[Risk] TROUBLESHOOTING.md becomes a dumping ground for edge cases** → **Mitigation**: Only include issues with verified resolutions and diagnostic commands. Spec requires "diagnostic commands with expected output" — speculative entries fail verification.

## Migration Plan

1. Write all five new guide files in `guides/`
2. Update `guides/README.md` as the index
3. Apply the delta spec to `openspec/specs/usage-guides/spec.md` (extends requirements)
4. Run `mix docs` to verify no broken links in generated documentation
5. Run `tools/install.sh --check` to verify daemon and CLI snippets still work
6. No deployment steps needed — documentation-only change

**Rollback**: Delete the five new files and revert the spec delta. No data migration or code rollback needed.

## Open Questions

- None. All design decisions are resolved. The specs fully define the requirements; the implementation is straightforward Markdown authoring.