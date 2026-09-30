# Design

## Context

See proposal.md Why for motivation. Current state shaping the approach:

- Source of truth is SQLite via the `AgentDb.Core.Storage` port (`Runtime.storage()`); `AgentDb.Application.Documents/Memories/Sessions` workflows own write semantics (cache invalidation, job enqueue, subscriptions, observability).
- Skills already solve the hard half of this problem in `AgentDb.Skills.Source`: in-memory `:erl_tar` table-then-extract, streaming gzip inflate with pre-assembly byte bound, `AgentDb.URI` path validation, duplicate/conflict checks, UTF-8 enforcement, entry/byte limits, validate-before-write with human-readable `message/1`.
- No full-store export/import exists; `AgentDb` facade has no `export_data/1` / `import_data/1`, and no Mix tasks exist for them. Specs: `specs/data-portability/spec.md` (new capability).

## Goals / Non-Goals

**Goals:**
- Offline tar handoff (`export_data` → file → `import_data`) that round-trips documents, memories, and sessions between stores.
- Same safety posture as skills import: validate everything before writing anything; refuse with an actionable reason.
- Reuse existing write paths so cache, jobs, PubSub, and telemetry behave identically for imported content.

**Non-Goals:**
- No WebSocket (`v1.export`/`v1.import`), MCP tools, or `/admin` UI in this change; CLI + facade only. Wire surfaces can be added later without changing the archive contract.
- No destructive restore/wipe, no cross-store sync, no conflict UI, no encryption/access control on the archive file itself.
- No change to SQLite schema, vector index format, or background job protocol.

## Decisions

### 1. Archive layout: manifest + three JSON payloads, `:erl_tar` in memory
- Layout: `manifest.json` (`format_version: 1`, `scope`, `exported_at`, counts, sha256 per payload), `documents.json` (`[{uri, content, abstract, overview}]`), `memories.json` (`[{uri, value, type, confidence, source, history}]`), `sessions.json` (`[{id, messages: [{seq, role, content}]}]`). All UTF-8 JSON.
- Plain `.tar` vs `.tar.gz` detected by magic bytes (same as skills `plain_tar/1`); export chooses by file extension, import by content not name.
- Alternative considered: raw SQLite file copy. Rejected: couples archives to internal schema/WAL state, bypasses storage-port abstraction (breaks custom providers), and carries derived embeddings/summaries that are cheaper to regenerate.
- Alternative considered: one-file-per-document tar members mirroring URI paths. Rejected: explodes entry counts against safety limits, complicates memory provenance + sessions, and duplicates path-validation work the JSON form gets once per URI.

### 2. Read through the storage port, write through the application workflows
- Export enumerates via `Runtime.storage()` reads (`list_children`/`get_node` walk scoped at `scope` or root) — never raw SQL — so custom `AgentDb.Core.Storage` adapters keep working.
- Import writes via `Documents.write/3` (with `abstract:`/`overview:`), `Memories.remember/3` (+ history replay), and session restore (`create` with preserved id if free else skip-if-identical, then `append_message` in seq order). This preserves cache invalidation, job enqueue (embed + missing summaries), `notify/2` broadcasts, and validation.
- Alternative considered: direct SQLite inserts for speed. Rejected: would bypass cache/job/subscription invariants the `context-store` specs require.

### 3. Additive merge, not replace; convergent re-import
- Import creates missing URIs and revises existing ones in place; never deletes store content outside the archive (unlike skill whole-subtree replacement, where the blast radius is one skill).
- Sessions keyed by id: identical message list → skip; unknown id → recreate with original id; colliding id with different messages → keep existing, report as skipped (no silent overwrite of a live conversation).
- Re-import converges because document/memory writes are idempotent by content and session commits use the existing converged-state rule.

### 4. Safety model cloned from skills, with transfer-sized limits
- Same enforcement order: `table` → count/declared-size check → `extract({:memory, max_size})` → per-URI `VikingURI` validation → UTF-8 check → manifest/schema check → write. Refused source writes nothing.
- New `AgentDb.Application.DataTransfer.limits/0` (`max_entries: 10_000`, `max_bytes: 50_000_000`) instead of reusing skill limits (500 / 5 MB): a whole store is larger than one skill bundle, but still bounded so a small archive cannot cost unbounded work. Counts cover documents + memories + session messages.
- Unsafe member/URI rules identical to skills: absolute, `..`, backslash, empty segment, control char, symlink/hardlink/non-regular, duplicate, non-UTF-8.

### 5. Derived data stays derived
- Archive carries only source layers (L2 + caller-supplied L0/L1) and memory/session source facts. Embeddings and generated summaries regenerate via the existing job queue after import; `model_status`/`queue_stats` observe the drain normally.

## Risks / Trade-offs

- [Large export held in memory] → Mitigation: byte/entry limits bound both sides; export streams reads but assembles one tar binary (documented; 50 MB cap keeps this acceptable for v1).
- [Concurrent writes during export give a non-atomic snapshot] → Mitigation: export is a best-effort point-in-time walk; import is convergent so a second export/import closes the gap. Documented in task help text.
- [Import replays history via public writes, so `source` session ids may dangle] → Mitigation: provenance strings are preserved verbatim; missing sessions resolve as opaque strings (same as cross-store copy). No FK enforcement added.
- [Format evolution] → Mitigation: `format_version` in manifest; import rejects newer versions with `{:unsupported_version, v}` instead of guessing.

## Migration Plan

- Additive only: new module + facade functions + two Mix tasks; no SQLite migration, no config change, no existing behaviour altered.
- Rollback: delete the imported URIs (`AgentDb.rm/1`, `forget/1`) or re-import the pre-change export; no archive-time state to unwind.

## Open Questions

- None. WebSocket/MCP exposure and subtree-delete-on-import (`--replace` mode) were requested implicitly by "other agent can import" but are deferred as non-goals; they do not change this archive contract or task breakdown.
