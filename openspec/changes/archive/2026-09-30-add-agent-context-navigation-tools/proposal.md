# Proposal

## Why

AgentDb already stores context in a URI-addressed tree and exposes listing, reading, semantic/keyword search, memories, and skills, but an agent cannot directly locate paths by name or inspect matching source lines. Adding bounded `find` and `grep` operations lets an agent progressively navigate stored context instead of relying on search results alone, while keeping task reasoning and execution in the host agent.

## What Changes

- Add in-process `find` and `grep` operations for URI-tree navigation and source-level inspection. Both support subtree scoping and bounded results; `find` matches stored paths, while `grep` matches literal text in L2 document content and returns line-oriented excerpts.
- Expose the operations as additive, versioned WebSocket events so remote agents can use them alongside the existing `list`, `read`, `search`, `remember`, and `recall` calls.
- Preserve existing document, search, memory, session, and skill behavior, including the current `viking://user/memories/...` memory URIs. Do not add an agent runtime, automatic session-memory extraction, intent analysis, or knowledge compilation.
- Document the new operations and their limits for library and WebSocket clients.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `context-store`: Add bounded path discovery and literal, line-oriented content matching over the existing context tree.
- `http-api`: Expose the new navigation operations through additive versioned WebSocket events.

## Impact

- **Code:** `AgentDb` facade and application workflows, the `AgentDb.Core.Storage` contract and its SQLite/test providers, the Phoenix channel, and README documentation.
- **Compatibility:** Existing `AgentDb` calls and `v1` events keep their contracts. Storage providers implementing `AgentDb.Core.Storage` must add the new callbacks; the runtime currently validates the complete port at startup.
- **Data/dependencies:** No schema migration or new dependency is expected. Existing URIs and stored records remain unchanged.
