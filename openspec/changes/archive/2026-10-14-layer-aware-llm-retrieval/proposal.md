# Proposal

## Why

L0/L1/L2 exist so an agent can decide what to read before paying to read it, but the two surfaces an LLM agent actually uses cannot reach the layers: the MCP tool inventory exposes only `context_read` (full L2) and `context_search` (which returns every hit's full content), and the CLI has no abstract/overview task at all. The layers are stored, generated, shown in the admin console, and served over WebSocket `v1.abstract`/`v1.overview` — and are invisible to the OpenCode and Zed clients the store exists to serve. An agent therefore either spends a whole document's tokens to learn one line about it, or ignores the layering entirely.

The layers themselves do not reliably repay the read either. Summarization prompts carry no length budget beyond a token cap and no instruction to prefer distinguishing terms, so a generated abstract can restate the obvious. The deterministic fallbacks are raw truncations: the abstract returns the first line including its markdown heading marker, and the overview slices 280 characters wherever the count lands, mid-word or mid-sentence.

## What Changes

- **Expose layer reads to LLM clients.** Add MCP tools `context_abstract`, `context_overview`, and `context_layers` (all three layers, each with source and size, in one call), accepting the same option names as the facade. Add `mix agent_db.abstract` and `mix agent_db.overview` CLI tasks with `--json`, following the existing read/find/grep/recall task shape.
- **Let a search answer with less.** Add an opt-in `:fields` option to `search/2` selecting which per-result fields are returned (`:uri`, `:abstract`, `:overview`, `:content`, `:score`), so a keyword, vector, or hybrid search can return URI plus abstract and score only. Default behavior is unchanged; an unrecognized field name is refused rather than ignored.
- **Make generated layers short and matchable.** Give the summarization prompts per-layer length budgets, a preference for distinguishing terms over generic ones, and the document's frontmatter identity as context so a skill's abstract states its purpose rather than its YAML block.
- **Make fallback layers short and matchable.** Strip leading markdown heading markers and list bullets from the L0 fallback, and truncate the L1 fallback on a word boundary so it never ends mid-word.
- **Document the layer workflow.** `guides/USAGE.md` and `guides/API-REFERENCE.md` describe the layer-first read path, the new tools and CLI tasks, and the `:fields` option.

## Capabilities

### New Capabilities

None. Every behavior in this change belongs to an existing capability boundary: layer generation is `llm-summarization`, layer reads and search projection are `context-store`, result shape is `vector-search`, the LLM-facing surfaces are `agent-tooling`, and the guides are `usage-guides`.

### Modified Capabilities

- `llm-summarization`: L0/L1 generation acquires per-layer length budgets, a preference for distinguishing terms, and the document's frontmatter identity as context.
- `agent-tooling`: the MCP tool inventory gains `context_abstract`, `context_overview`, and `context_layers`; the machine-readable CLI fallback gains `mix agent_db.abstract` and `mix agent_db.overview`.
- `context-store`: `search/2` gains a per-result field selection option that defaults to today's full result set, and the deterministic L0/L1 fallbacks stop emitting markdown heading markers and stop truncating mid-word.
- `vector-search`: vector and hybrid results become selectable by field, with the default carrying URI, content, abstract, overview, and score unchanged.
- `usage-guides`: `guides/USAGE.md` and `guides/API-REFERENCE.md` document the layer-first workflow for LLM clients and keep the MCP list matching `AgentDbWeb.Mcp.tools/0` exactly.

## Impact

**Code**
- `lib/agent_db_web/mcp.ex` — three new tool definitions and dispatch arms, plus a `:fields` argument on `context_search`.
- `lib/mix/tasks/agent_db.abstract.ex`, `lib/mix/tasks/agent_db.overview.ex` — new CLI tasks.
- `lib/agent_db/application/search.ex` — field-selection projection applied once, before results are projected.
- `lib/agent_db/workers/workers.ex` — revised `prompt/2` shapes and per-layer budgets.
- `lib/agent_db/application/documents.ex` — fallback heading-marker stripping and word-boundary truncation.

**Unchanged**
- `AgentDb.abstract/1`, `overview/1`, `stored_layers/1`, `read/1` signatures and their WebSocket `v1.*` handlers.
- The stored `nodes` schema and the job kinds (`:summarize_abstract`, `:summarize_overview`).
- Default search result shape and default layer read behavior; existing callers and the existing MCP tools behave as they do today.

**Docs and tests**
- `guides/USAGE.md`, `guides/API-REFERENCE.md`.
- `test/agent_db_web/mcp_test.exs`, `test/agent_db/search_bounds_test.exs`, `test/agent_db/documents_frontmatter_test.exs`, summarization and workers tests, plus new CLI task tests — all under the existing `mix test`, `mix format --check-formatted`, and `mix compile --warnings-as-errors` gates.
