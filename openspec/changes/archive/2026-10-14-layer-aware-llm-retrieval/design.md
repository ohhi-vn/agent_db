# Design

## Context

See `proposal.md` for motivation. This section records only the current state that constrains the approach.

Observed today:

- `AgentDb.Application.Search` is the single owner of all three search modes. Its keyword leg projects through `entry/1` (`%{uri, content, abstract, overview}`), its vector leg through `strip_meta/1`, and hybrid fuses the two already-built lists. Both legs talk to storage through `Runtime.storage()`, whose `search_keyword/3` and `search_vector/3` callbacks both SELECT every node column — `content` included — from SQLite.
- `AgentDbWeb.Mcp` maps tool names onto the `AgentDb` facade. It has no layer-read tool, and `context_search` passes through whatever `AgentDb.search/2` returns.
- `AgentDbWeb.Context.get_layers/1` already computes the layer view the console renders (`text`, `source`, `chars`) by calling four facade functions (`stored_layers/1`, `abstract/1`, `overview/1`, `read/1`). That shaping exists today but lives in the transport layer.
- `AgentDb.Workers.Summarization.prompt/2` owns the two prompts; `generate/1` passes the provider's answer straight through. Reasoning stripping happens inside each backend (`strip_reasoning/1` in the EXLA and EMLX adapters), before the worker sees the text.
- The frontmatter parsing that the L0/L1 fallbacks use (`split_frontmatter/1`, `frontmatter_identity/1`) is private to `AgentDb.Application.Documents`.
- `AgentDb.Application.Documents.jobs_for/3` builds the job payload (`uri`, `content`, optional `_trace`) which `JobQueue` JSON-encodes into `job_queue.payload`.

Constraints that shape the approach:

- `test/agent_db/boundaries_test.exs` asserts that every module in `@core` names only an allow-list of modules, and that every `AgentDbWeb` module reaches the store only through the `AgentDb` facade. Any new module referenced by a core workflow must be added to that allow-list or the test fails.
- `test/agent_db/core/contracts_test.exs` asserts an operation exists for every callback on `AgentDb.Core.Storage`, and `test/support/storage_contract.ex` exercises those callbacks against each adapter.
- The project's established rule for bounded reads (`:top_k`) is that the bound goes down to storage rather than being applied to what storage returned, because "an unbounded scan materializes every match and then discards all but the first few, which is the whole cost the bound exists to avoid" (`search.ex`).

## Goals / Non-Goals

**Goals:**

- A layer read reachable from the two LLM surfaces (MCP, CLI) with one call each, and one all-layers call.
- A search that can answer with URIs and abstracts only, where "only" is true at the storage read, not only at the JSON encoding.
- Layer text that is bounded and scannable whether it was generated or derived.
- One definition of the layer view, shared by the console and MCP.

**Non-Goals:**

- Changing what `AgentDb.abstract/1`, `overview/1`, `read/1`, and `stored_layers/1` return, or their signatures.
- Changing the default search result set, the `nodes` schema, job kinds, or the summaries already stored.
- Windowed or partial reads of L2 (explicitly out of the confirmed scope).
- Improving search ranking, hybrid weights, or vector index behavior.
- Backfilling or regenerating layers for documents already summarized.

## Decisions

### D1 — Field selection is pushed down to the storage adapter

`search/2` gains `:fields`. The projection is applied by the adapter, not by the application: `search_keyword/3` becomes `search_keyword/4` and `search_vector/3` becomes `search_vector/4`, each taking the validated field list. The adapter builds its SELECT column list from the requested fields plus the internal columns the application still needs (`enabled` for the disabled filter, `group_tag` for `strip_meta/1`), and maps rows by the column order it asked for.

Why not project in `AgentDb.Application.Search` instead: SQLite would still read and materialize `content` for every matching row, so the only saving would be in JSON serialization — the small half of the cost. The project has already chosen the other half once, for `:top_k`, and for the same reason.

Why not a separate callback (`search_keyword_projected/4`): two contracts for one question, and the contract test enumerates one operation per concern. One callback with a projection argument keeps the contract test's assertion true.

Consequence to accept: the callback arity changes, so `AgentDb.Core.Storage`, `AgentDb.Adapters.SQLite`, `AgentDb.Store.Nodes`, `test/agent_db/core/contracts_test.exs`, `test/support/provider_fakes.ex`, and `test/support/storage_contract.ex` all move together. The storage contract suite is where the new behavior gets its adapter-level scenarios.

### D2 — `:uri` is mandatory in a `:fields` selection

A `:fields` list that omits `:uri` returns `{:error, {:invalid_fields, value}}`, as does an empty list and any name outside the five. A result without its URI cannot be used to fetch the document, and silently re-adding it would answer a question the caller did not ask.

Why not always include `:uri`: the project refuses rather than substitutes for every other bounded option (`:top_k` out of range is an error, not a default). A projection that quietly re-adds a field would be the only option that behaves the other way.

`nil` (the option absent) means the full default set, so every existing caller is unchanged.

### D3 — One layer view, computed by the facade

`AgentDb.layers/1` is added to the facade and returns

```elixir
%{
  abstract: %{text: String.t(), source: :stored | :fallback | :unavailable, chars: non_neg_integer()},
  overview:  %{text: String.t(), source: :stored | :fallback | :unavailable, chars: non_neg_integer()},
  content:   %{text: String.t(), source: :stored | :unavailable, chars: non_neg_integer()}
}
```

`AgentDbWeb.Context.get_layers/1` becomes a delegate that renames those keys to the `l0`/`l1`/`l2` the console's templates already use, so the console renders exactly what it renders today. MCP's `context_layers` maps the same function to its own JSON keys.

Why the facade rather than the web layer computing it: whether a layer was stored or derived is store knowledge — it is the difference between what a caller supplied and what the read path resolved. `AgentDbWeb.Context.get_layers/1` currently computes it from four facade calls, which is the same answer assembled twice, and MCP would have been the third. One definition also keeps MCP inside the boundary the boundaries test enforces.

Why `abstract`/`overview`/`content` and not `l0`/`l1`/`l2` in the facade: the facade's own vocabulary is `abstract` and `overview` (`write/3` takes `:abstract` and `:overview`). The `l0`/`l1`/`l2` names are the console's presentation, and translation at the transport edge is what that edge is for.

`context_abstract` and `context_overview` remain one facade call each (`AgentDb.abstract/1`, `AgentDb.overview/1`) and answer with `%{"uri" => uri, "abstract" => text}` / `%{"uri" => uri, "overview" => text}`, mirroring `context_read`'s `%{"uri" =>, "content" =>}`. They need no model when the layer is stored, which is the case that matters most to a client deciding whether to read L2.

### D4 — Layer bounds are enforced by the worker, not trusted from the prompt

`Workers.Summarization.generate/1` trims the provider's answer to the layer's budget after the backend has stripped reasoning: one sentence for an abstract, five for an overview. A trim that lands exactly on the bound is not an error.

Why in the worker: the provider is replaceable, and a provider that ignores the prompt's length instruction would otherwise store an unbounded layer. The prompt asks; the worker enforces. Enforcement belongs after reasoning stripping so a trimmed result is real answer text and never reasoning.

Why not in the backends: both backends would need the same sentence logic, and the budget is a property of the layer, which is the worker's concept. The backends' job stays turning text into text.

Sentence boundaries: `.`, `!`, `?` followed by whitespace or end of input, plus a newline. An abstract that trims to nothing keeps the provider's answer rather than storing an empty layer, because the existing empty-summary contract is about a provider that produced nothing, not about a bound.

### D5 — Frontmatter identity travels in the job payload

`Documents.jobs_for/3` computes the frontmatter identity once at write time using the parser that already lives in that module, and puts it in the summary jobs' payload as `"identity"`. `Workers.Summarization.generate/1` reads it and passes it to `prompt/3`, which becomes `prompt(layer, content, identity)`; a missing key reads as `nil` and the prompt is built without identity context.

Why the payload rather than a shared parser module: the frontmatter parser is private to `Documents` on purpose. Extracting it into a new module would add a second definition risk *and* require updating the boundaries test's allow-list, because a core workflow would name a module not currently on it. Carrying the identity in the payload keeps one definition, computes it once per write instead of once per retry, and degrades correctly for jobs already in the durable queue.

Why not the URI: the worker's job is to turn content into a layer; fetching the node again would make a summary job do a read it does not need.

### D6 — Fallback changes are local to `Documents`

`first_line/1` gains marker stripping for leading `#`, `>`, `-`, `*`, and `+` (with the whitespace that follows them), applied only when something remains, so a line that is only markers keeps its original text rather than becoming empty. `first_chars/1` truncation backs off to the last whitespace inside the 280-character bound, matching the convention the grep excerpts already use (a raw slice, no ellipsis). The 280 bound itself and the frontmatter identity truncation are unchanged.

## Risks / Trade-offs

- **The storage callback arity change touches every adapter and contract test.** → Both adapters and the shared contract suite are updated in the same change, and the contract test keeps asserting the operation list. The behavior under test (default projection returns the same fields as before) is the compatibility guard.
- **A dynamic SELECT column list is string-built SQL.** → The column names come from a closed allow-list of atoms mapped to fixed SQL fragments, never from caller text. The existing statement still binds `term`, `prefix`, and `limit` as parameters.
- **Row mapping by column order is positional and fragile.** → The adapter builds the column list and the row mapper from the same list, so they cannot disagree; a rank/order mismatch would be caught by the contract suite's shape assertions rather than reaching a caller.
- **Provider sentence trimming can split an abbreviation** (`e.g. "Fig. 3"`). → A trim that lands on a false boundary yields a slightly shorter abstract, never a wrong one. The alternative — no trimming — gives up the bound whenever a provider ignores the prompt.
- **Prompt changes alter generated layer text for documents summarized after this change**, so a store may hold layers generated by the old prompt beside ones generated by the new one. → Accepted: layers are regenerated on content change, and the change does not re-summarize on boot. Mixed provenance is visible through `stored_layers/1`.
- **Existing MCP clients are unaffected but gain nothing until they use the new tools.** → The layer tools are additive; `guides/USAGE.md` documents the layer-first path so a client has something to follow.
- **A `:fields` selection that omits `:content` silently makes a search unable to show a match context.** → The caller asked for it, the error path refuses unusable selections, and the default is unchanged.

## Migration Plan

No data migration. No configuration change. No restart ordering concern: the change is additive at the wire level, and the one arity change is internal to the process.

Rollback: revert the change. Layers generated by the new prompts stay in `nodes` and remain valid — `abstract/1` and `overview/1` return them unchanged, because nothing in the read path depends on which prompt produced a layer.

## Open Questions

None that would change the specs, the approach, or the task breakdown.
