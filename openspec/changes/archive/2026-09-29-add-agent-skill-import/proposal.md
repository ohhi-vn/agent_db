# Proposal

## Why

AgentDb already has a `user/{user_id}/skills` subtree and stores documents through one shared facade, but users must currently write skill files individually. Importing standard Agent Skills bundles from the operations UI or a local command makes existing skills usable without hand-copying each file.

## What Changes

- Add import of one Agent Skill or a collection of skills from a directory or tar archive into a selected user's skills subtree.
- Provide the same import behavior through the admin UI and an Elixir Mix task.
- Preserve each skill's `SKILL.md` and supporting files; replace the complete stored subtree for a same-name skill, as selected by the user.
- Validate bundle structure and paths before writing, reject unsafe or invalid entries, and report per-skill outcomes.

## Capabilities

### New Capabilities
- `agent-skills`: Import Agent Skills from directories and tar archives through the UI and CLI into the existing per-user skills tree.

### Modified Capabilities

None. The existing `context-store` capability already defines the generic tree and document behavior; this change adds skill-import behavior on top of it.

## Impact

- The `AgentDb` facade and application workflow, storage contract, and SQLite adapter for safe replacement of a skill subtree.
- `AgentDbWeb.AdminLive` for upload and result reporting, plus a Mix task for local command-line imports.
- Tests and user documentation for accepted bundle layouts, destination user IDs, replacement behavior, and import errors.
- No new runtime dependency or WebSocket API operation is planned; use Erlang's built-in tar support and the existing application surfaces.
