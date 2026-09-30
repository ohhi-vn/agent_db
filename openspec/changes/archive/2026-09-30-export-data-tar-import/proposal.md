# Proposal

## Why

Agents running separate `agent_db` instances have no portable way to share context. Skills can already be imported from tar, but documents, memories, and sessions cannot leave one store and land in another. A tar-based export/import closes that gap with an offline, file-based handoff.

## What Changes

- Add `AgentDb.export_data/1-2` that snapshots store content (documents with caller-supplied L0/L1 + full L2, memory provenance, sessions) into a single `.tar` / `.tar.gz` file.
- Add `AgentDb.import_data/1-2` that restores a previously exported tar into the running store, validating structure before writing anything.
- Add Mix tasks `mix agent_db.export_data <path>` and `mix agent_db.import_data <path>` with `--json` output and non-zero exit on failure, reusing the existing CLI conventions.
- Refuse unsafe or malformed archives (absolute paths, `..` traversal, symlinks/hardlinks, non-UTF-8 content, oversize payloads) with a human-readable reason; a refused import writes nothing.
- Import is additive-merge by URI: existing URIs are revised in place (memories keep supersession history), missing URIs are created; nothing outside the exported set is deleted.

## Capabilities

### New Capabilities

- `data-portability`: portable full/subtree export of context-tree documents, memories, and sessions to a tar archive and validated import of that archive into another store.

### Modified Capabilities

- None. Existing `context-store`, `memory`, `agent-tooling`, and `http-api` REQUIREMENTS are unchanged; this adds a parallel transfer surface on top of the same facade workflows.

## Impact

- Core: new `AgentDb.Application.DataTransfer` workflow + facade functions; reuse `:erl_tar`, `AgentDb.URI` validation, and skills-style size/entry limits.
- CLI: two new Mix tasks following `agent_db.import_skills` patterns (`--json`, stderr reason, non-zero exit).
- No change to SQLite schema, vector index format, HTTP/WebSocket wire protocol, or existing specs. Embeddings/summaries regenerate via the existing job queue after import; they are not carried in the archive.
