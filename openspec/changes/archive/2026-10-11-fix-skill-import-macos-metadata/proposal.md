# Proposal

## Why

Skill import refuses entire valid bundles on macOS because Finder/AppleDouble metadata files (`._SKILL.md`, `.DS_Store`) travel inside skill folders: reproduced as `mix agent_db.import_skills .../easy-rpc --user alice` → `Refused: ._SKILL.md is not valid UTF-8 text`, nothing imported. Any folder touched by Finder (notably on external/non-HFS volumes, where AppleDouble sidecars are always materialized) is unimportable.

## What Changes

- The importer sets aside OS-metadata entries — basenames starting with `._` (AppleDouble sidecars) and `.DS_Store` — instead of refusing the bundle for them, uniformly across folder, archive, and browser-upload sources.
- Skipped entries consume no budget (file-count/byte limits), take no part in layout checks (missing-manifest, loose-file, duplicate, conflict), and are never stored.
- A source holding only metadata (no skill) is still refused (`no_skills` / `missing_manifest`), as today.
- Docs updated (`Source` moduledoc, Mix task "What it refuses") to state the set-aside.

## Capabilities

### New Capabilities

None — this adjusts existing validation behavior, not a new capability.

### Modified Capabilities

- `agent-skills`: the "Validate imports before changing stored data" requirement — OS-metadata entries are set aside rather than refused; the "Preserve skill files and relative paths" requirement is unaffected (stored files are still exactly the skill's text files).

## Impact

- Affected code: `lib/agent_db/skills/source.ex` only (the single place deciding what a bundle holds), plus its moduledoc; `lib/mix/tasks/agent_db.import_skills.ex` moduledoc line.
- APIs: no shape change; fewer `{:error, ...}` outcomes for bundles containing metadata files. No migration.
- Out of scope: other hidden/metadata conventions (`.Trashes`, `.Spotlight-V100`, `.fseventsd` live at volume roots, not inside skill folders); reporting skipped files (no warnings channel exists — silent set-aside, documented).
