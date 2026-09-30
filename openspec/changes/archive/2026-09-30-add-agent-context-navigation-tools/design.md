# Design

## Context

The public `AgentDb` module delegates tree operations to `Application.Documents` and ranked retrieval to `Application.Search`. Both workflows reach durable data through the complete `Core.Storage` port; the default SQLite adapter stores directory and document nodes together in `nodes`. The Phoenix channel maps versioned events through the facade and explicitly whitelists JSON options. See `proposal.md` and the spec deltas for the motivation and observable contracts.

## Goals / Non-Goals

**Goals:**

- Keep path discovery, content inspection, and ranked search as distinct operations with consistent scope validation and bounded responses.
- Preserve storage-provider replaceability and ensure remote and in-process callers receive the same validation and results.
- Keep the new operations read-only and free of inference/model dependencies.

**Non-Goals:**

- Changing URI layout, memory identity, document writes, ranked search, or the `v1` response envelope.
- Providing regular-expression support, an agent execution loop, automatic memory extraction, or a knowledge compiler.

## Decisions

### Extend the existing document and search workflows

Add `find/2` to `Application.Documents`, where tree navigation already lives, and add `grep/2` to `Application.Search`, where content retrieval already lives. Expose both through the `AgentDb` facade. This keeps the application layer responsible for API validation and result shaping without adding a new single-purpose service or duplicating the existing storage/runtime boundary.

### Put subtree matching and bounded result production behind the storage port

Add focused storage callbacks for path matches and line matches. The SQLite adapter will implement them through `Store.Nodes`, where node ownership and current literal-search escaping already reside. The callbacks receive the validated query, exact scope URI (or `nil`), and validated limit; scope membership is exact-URI-or-descendant, not a raw prefix that can match a sibling such as `project-old`. `find` returns path metadata only. `grep` returns line hits with one-based line numbers and bounded excerpts, and matches only L2 content.

Composing repeated `list/1` and `read/1` calls in the application layer was considered. It would load many nodes into the caller, produce N+1 storage reads, and make the response cap difficult to enforce uniformly. Keeping matching in the provider makes the storage contract explicit and lets other configured providers implement the same behavior. Since `Runtime.validate!/0` checks every callback, all custom storage adapters must add the callbacks before using this release; the test provider and storage contract suite will be updated with the SQLite adapter.

### Use literal substring matching, not a query language

Both operations accept valid UTF-8 query strings from 1 through 256 characters. Path and content matches are case-insensitive literal substrings; `%`, `_`, backslashes, and regular-expression metacharacters have no special meaning. SQLite statements will bind all caller values and escape LIKE metacharacters using the existing node helper. A scope is parsed as a `viking://` URI and checked for existence before results are returned. Empty/malformed values and limits outside 1 through 200 return classified errors rather than being silently coerced.

Literal matching is intentionally narrower than glob or regex support. The task is progressive navigation and source inspection; a query language would add escaping, resource-exhaustion, and cross-provider compatibility rules without being needed for the current API.

### Add only WebSocket events for remote agents

Expose `v1.find` and `v1.grep` in `AgentDbWeb.Channel`, with required `term` and only the `scope` and `limit` option keys. Responses use the existing `%{results: ...}` success envelope and existing error renderer. The channel maps only known string keys to internal option names, never creating atoms from payload values. No new REST routes are needed for the selected agent workflow, and existing connection authentication remains the boundary for remote calls.

### Keep limits fixed and results stable

Use the spec's default limit of 50 and hard maximum of 200 for both operations. Sort `find` results by URI and `grep` results by URI then line number before applying the limit. Return no document body from `find`; return at most 280 characters around each matching line from `grep`. Fixed limits bound context returned to an agent without introducing configuration whose value has no deployment-specific reason to vary.

## Risks / Trade-offs

- **Custom storage adapters need a port update** → Add callbacks to the storage contract, update the in-repo fake, and document the startup compatibility requirement. No existing database rows need migration.
- **Literal scans may be slower on very large trees** → Apply subtree filtering and result limits in the storage provider, use existing SQLite indexes where applicable, and benchmark before adding a text index or changing the storage model.
- **Malformed wire input could cause inconsistent errors or unsafe query construction** → Validate query/scope/limit in the application workflow, whitelist channel options, bind SQL parameters, and test special characters plus same-connection recovery after an error.
- **Long matching lines could inflate context results** → Keep each grep excerpt at or below 280 characters while ensuring it contains the match.

## Migration Plan

No schema or data migration is required. Update every configured `Core.Storage` implementation in the same release as the new facade operations, since startup rejects providers missing required callbacks. Rollback requires only reverting the application/API change; the new operations write no persistent state, so stored documents and existing clients are unaffected.
