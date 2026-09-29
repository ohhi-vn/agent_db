# Design

## Context

See `proposal.md` for motivation and `specs/agent-skills/spec.md` for the behavior contract. The store exposes stable operations through `AgentDb`, then application workflows reach the replaceable `AgentDb.Core.Storage` port. The SQLite adapter serializes writes and already treats subtree removal as one transaction across documents, vectors, and queued jobs; the read cache is invalidated by application workflows after committed writes. `AgentDbWeb.AdminLive` is the existing browser console. There is no project Mix task for user data today. The database already stores ordinary documents under `viking://user/{user_id}/skills`.

## Goals / Non-Goals

**Goals:**
- Normalize UI uploads, local directories, and tar archives into one validated skill representation and one import workflow.
- Make a same-name replacement atomic per skill while preserving the existing URI-tree, cache, vector, and background-job invariants.
- Keep archive and folder handling local, bounded, and free of filesystem extraction or a new runtime dependency.

**Non-Goals:**
- Executing skills, resolving their runtime dependencies, or adding skill discovery/invocation APIs.
- Importing binary assets; this design stores UTF-8 text documents, consistent with the current content contract.
- Parsing or rewriting `SKILL.md` frontmatter. The directory name is the stored skill name and the file is preserved verbatim.
- Adding a WebSocket endpoint or changing the existing browser-console access policy.

## Decisions

### One application workflow serves both entry points

Add a skill-import workflow behind the `AgentDb` facade. It accepts a selected user ID and normalized files for one or more skills, validates the complete source, then asks the storage port to replace skills. The admin LiveView owns upload and result presentation; a Mix task owns local path and command-line argument handling. Neither entry point parses archives or writes individual documents itself.

For a browser directory selection, the LiveView passes each upload's client-relative path and content to the same normalizer used by the CLI. The CLI accepts a directory or TAR / gzip-compressed TAR path. The Mix task starts the application before invoking the facade and exits unsuccessfully if any skill result failed.

### Normalize and validate before any store mutation

Use `File.lstat` while walking directory sources so links are rejected rather than followed. Use Erlang's built-in `:erl_tar` support to read TAR input, including gzip-compressed TAR, without extracting entries to disk. Normalize an optional single archive wrapper and accept only a skill root or a collection of immediate skill directories. Each skill must contain a root `SKILL.md`; all stored paths are relative to the skill root.

Validate user ID, skill names, and every path segment with the same URI-segment rules as the context store. Reject duplicate normalized paths, unsafe path forms, non-regular entries, malformed packages, and invalid UTF-8 before writing anything. Enforce fixed limits for compressed input, entry count, and expanded content in the shared workflow rather than introducing configuration that differs between the UI and CLI. Keep `SKILL.md` opaque; a YAML parser would add a dependency without being needed to preserve or store the skill.

### Put complete subtree replacement at the storage boundary

Extend `AgentDb.Core.Storage` with a batch skill-replacement operation and implement it in the SQLite adapter on the serialized writer connection. For each skill, one SQLite transaction removes any existing subtree and its URI-keyed state, creates the new directory/document nodes, and enqueues the normal asynchronous document work for the new text files. A failed step rolls the transaction back, leaving the old subtree intact. Each skill is its own transaction so a valid multi-skill import can report partial success without misreporting which skills committed.

After a successful transaction, the application workflow invalidates the cache for the replaced skill subtree before reporting success. This follows the existing ownership split: the adapter keeps durable URI-keyed data in agreement; the application workflow keeps cached reads in agreement with committed storage. Update storage contract fakes and tests for the new callback.

This uses a batch storage operation instead of calling `AgentDb.write/3` repeatedly: repeated writes would leave a partial replacement on error, retain stale files omitted by the new source, and separate old vector/job cleanup from the new document set.

### Keep limits and results consistent across interfaces

The shared workflow owns fixed file-count, compressed-size, and expanded-size limits. The UI also configures its upload cap to no more than the workflow's accepted input bound. Report imported, replaced, and failed names with an actionable reason. Source validation failure rejects the full source before any write; after validation, storage failures are isolated and reported per skill.

## Risks / Trade-offs

- [A malicious or highly compressed archive can consume CPU or memory] → Bound compressed bytes, entry count, and expanded bytes before mutation; never extract archive paths to the filesystem.
- [The storage port is implemented by more than SQLite in tests or integrations] → Add the batch callback to the storage contract and contract fixtures in the same change.
- [The current UI and CLI content contract is text-oriented] → Reject non-UTF-8 files explicitly instead of silently corrupting or omitting skill assets.
- [The admin UI follows the existing browser trust boundary] → Keep the import action inside the existing admin surface, retain its CSRF protections, and add no new network route or authentication bypass.

## Migration Plan

No database schema migration is needed: imported files use the existing URI-addressed document tree and background-job tables. Rollback consists of reverting the importer and UI/task code; already imported skills remain ordinary documents and can be removed through the existing subtree-removal operation.

## Open Questions

None. The existing per-user skill subtree supplies the destination model, and the user selected full replacement for same-name skills.
