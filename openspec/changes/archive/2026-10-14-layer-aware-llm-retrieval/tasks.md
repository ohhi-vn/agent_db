# Tasks

## 1. Storage-level field projection

- [x] 1.1 Change the `AgentDb.Core.Storage` callbacks `search_keyword/3` and `search_vector/3` to `search_keyword/4` and `search_vector/4`, each taking a validated field list where `nil` means today's full default set, and document in the callback docs that `:uri` is always returned regardless of the selection. Verify: `mix compile --force --warnings-as-errors` reports no missing callback and no warning.
- [x] 1.2 Add the projection to `Nodes.search/5`: build the SELECT column list from the requested fields plus the internal columns the application still needs (`enabled`, `group_tag`), and map each row by the column order that statement asked for, so `content` is not read when it was not selected. Verify: a keyword search selecting `[:uri, :abstract]` returns those fields and no `:content`, and one with `nil` returns exactly today's shape.
- [x] 1.3 Add the same projection to the vector search in `AgentDb.Adapters.SQLite` (`run_vector_search/6`), mapping the `distance` column alongside the selected node columns. Verify: a vector search selecting `[:uri, :score]` returns those fields with scores unchanged from an unselected search.
- [x] 1.4 Update `test/support/provider_fakes.ex` and `test/support/storage_contract.ex` for the new arity, and add contract scenarios for the projected shape and the default shape. Verify: `mix test test/agent_db/core/contracts_test.exs` passes with the operation list still asserted.
- [x] 1.5 Add a contract assertion that a dynamic column list never interpolates a caller-supplied name into SQL — the field atoms map to fixed fragments. Verify: the contract suite fails if a `:fields` value reaches SQL as raw text.

## 2. Field selection in the search workflow

- [x] 2.1 Add `:fields` validation to `AgentDb.Application.Search` (allow-list of `:uri`, `:abstract`, `:overview`, `:content`, `:score`; `:uri` required; empty or unknown names return `{:error, {:invalid_fields, value}}`) and apply the projection to each leg's results after the disabled filter, before ranking. Verify: `mix compile --force --warnings-as-errors` passes and a search with `fields: [:uri, :checksum]` returns `{:error, {:invalid_fields, [:uri, :checksum]}}`.
- [x] 2.2 Confirm the projection reaches storage: `AgentDb.Application.Search` passes the validated fields to `Runtime.storage().search_keyword/4` and the vector leg to `search_vector/4`, with `nil` when the option is absent. Verify: an omitted `:fields` produces byte-identical results to before the change.
- [x] 2.3 Add tests in `test/agent_db/search_bounds_test.exs` for the selected shape, the default shape, the refusal of unknown and missing-`:uri` selections, and identical results across `:keyword`, `:vector`, and `:hybrid` for the same selection. Verify: `mix test test/agent_db/search_bounds_test.exs test/agent_db/hybrid_search_test.exs` passes.
- [x] 2.4 Document the `:fields` option in `guides/API-REFERENCE.md` beside `AgentDb.search/2` and in the `context_search` tool entry. Verify: every documented option name exists in the search option vocabulary and the guide's snippet runs as written.

## 3. One layer view on the facade

- [x] 3.1 Add `AgentDb.layers/1` returning `%{abstract: layer, overview: layer, content: layer}` with each layer carrying `text`, `source` (`:stored` | `:fallback` | `:unavailable`), and `chars`, reusing `stored_layers/1` to tell a stored layer from a derived one. Verify: `AgentDb.layers/1` on a stored document with no stored layers reports `:fallback` for L0 and L1 and `:stored` for L2.
- [x] 3.2 Make `AgentDbWeb.Context.get_layers/1` a delegate that renames the facade's keys to the `l0`/`l1`/`l2` the console templates already use, deleting the four-call assembly. Verify: `mix test test/agent_db_web/context_test.exs` passes unchanged, and the rendered console layers are identical to before.
- [x] 3.3 Add `@spec` and `@doc` for `AgentDb.layers/1` in the facade's "Layered content" section so it appears in generated docs. Verify: `mix docs` succeeds and lists `AgentDb.layers/1`.

## 4. MCP layer tools

- [x] 4.1 Add `context_abstract`, `context_overview`, and `context_layers` to the tool inventory in `AgentDbWeb.Mcp.tools/0` and their dispatch arms, answering `%{"uri" =>, "abstract" =>}` / `%{"uri" =>, "overview" =>}` and the facade's layer map for the all-layers tool, with the same JSON-RPC error handling as the existing tools. Verify: `tools/list` returns the three new names and a `tools/call context_layers` on a stored URI returns all three layers with text, source, and character count.
- [x] 4.2 Add a `fields` argument to the `context_search` tool schema, passed through under the same name, so an LLM client can ask for URIs and abstracts only. Verify: `tools/call context_search` with `fields` returns only the selected fields and omits document content.
- [x] 4.3 Add tests to `test/agent_db_web/mcp_test.exs` covering the three new tools, the layered response shape, one unavailable layer not failing the others, the projected search response, and the layer tools answering without any model loaded. Verify: `mix test test/agent_db_web/mcp_test.exs` passes.
- [x] 4.4 Verify the MCP list in `guides/USAGE.md` still matches `AgentDbWeb.Mcp.tools/0` exactly, adding the three new tools to the guide. Verify: a comparison of the guide's tool list against the registry finds no tool listed that the registry does not define and no registry tool left undocumented.

## 5. CLI layer tasks

- [x] 5.1 Add `Mix.Tasks.AgentDb.Abstract` and `Mix.Tasks.AgentDb.Overview` in `lib/mix/tasks/`, each taking one URI, supporting `--json` and `--no-compile`, printing raw text without `--json`, and exiting non-zero with the reason on stderr on failure. Verify: `mix agent_db.abstract viking://resources/foo.md --json` prints the abstract as JSON and a missing URI exits non-zero with the reason on stderr.
- [x] 5.2 Add CLI task tests in `test/mix/tasks/context_tasks_test.exs` following the existing `agent_db.read` task test shape, covering `--json`, the human-readable default, and the non-zero exit for both new tasks. Verify: `mix test test/mix/tasks/context_tasks_test.exs` passes for the abstract and overview tasks.
- [x] 5.3 Add both tasks to `guides/API-REFERENCE.md`'s CLI table and to the `Command line` docs group. Verify: `mix docs` succeeds and both tasks appear in the generated CLI reference.

## 6. Layer bounds and prompts

- [x] 6.1 Add sentence-boundary trimming to `AgentDb.Workers.Summarization.generate/1` — one sentence for `:summarize_abstract`, five for `:summarize_overview` — applied after the provider returns, on `.`, `!`, `?` followed by whitespace or end of input and on newlines, leaving an answer that trims to nothing as the provider returned it. Verify: a scripted provider returning six sentences stores one sentence as the abstract and five as the overview, and a provider returning fewer than the budget is stored unchanged.
- [x] 6.2 Rewrite `prompt/2` as `prompt/3` taking the optional frontmatter identity, with each layer's length budget stated in the prompt itself, a request for distinguishing terms over generic ones, and the identity passed as context rather than as text to summarize. Verify: the generated prompt for a document with `name:`/`description:` names the identity as context and states the sentence budget.
- [x] 6.3 Carry the frontmatter identity in the summary job payload: `AgentDb.Application.Documents.jobs_for/3` computes the identity once using the existing private parser and adds it as `"identity"`, and `generate/1` reads it with `nil` for payloads that predate the field. Verify: a document with frontmatter enqueues summary jobs whose payload carries `"identity"`, and a payload without the key still summarizes from content alone.
- [x] 6.4 Add tests to `test/agent_db/ml/summarization_prompt_test.exs` and `test/agent_db/workers/job_worker_correlation_test.exs` for the trim bounds, the identity context in the payload, the degraded path for a payload without identity, and unchanged summarization for a caller-supplied layer. Verify: `mix test test/agent_db/ml/summarization_prompt_test.exs test/agent_db/workers` passes, including the existing reasoning-stripping and empty-summary cases.

## 7. Deterministic fallback quality

- [x] 7.1 Strip leading `#`, `>`, `-`, `*`, and `+` markers (with following whitespace) from the abstract fallback in `AgentDb.Application.Documents`, applied only when text remains so a line of only markers keeps its original text. Verify: a document whose first line is `## Storage layout` has `abstract/1` return `Storage layout`, and a plain first line is returned unchanged.
- [x] 7.2 Truncate the overview fallback at the last whitespace inside the existing 280-character bound, leaving the bound itself and the grep excerpt convention unchanged. Verify: a long body's `overview/1` ends at a word boundary with no partial word, and a short body is returned whole.
- [x] 7.3 Add tests to `test/agent_db/documents_frontmatter_test.exs` for marker stripping, word-boundary truncation, and the unchanged frontmatter identity and non-frontmatter fallbacks. Verify: `mix test test/agent_db/documents_frontmatter_test.exs` passes.

## 8. Guides and integration

- [x] 8.1 Add the layer-first read path to `guides/USAGE.md`: read L0 then L1 before L2, the `context_abstract`/`context_overview`/`context_layers` tools, the two new CLI tasks, the `fields` search option, and that a fallback layer is derived from L2 and how a caller tells. Verify: every tool, task, and option name in the new section matches the code, and each snippet runs as written.
- [x] 8.2 Run the project's gates over the whole change: `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix test`, `mix docs`, and `mix lint`. Verify: all pass with zero warnings, and no test file regresses against the pre-change baseline.

## Workflow follow-up

- Confirm `openspec validate layer-aware-llm-retrieval --strict` still passes after any spec edit made during implementation.
- Archive the change once the project's review requirements are satisfied, then verify the archived result against `openspec/specs/`.
