# Proposal

## Why

On `/admin/skills`, selecting a folder or archive shows nothing: the form has no `phx-change` and uploads are not `auto_upload`, so file selection performs no server roundtrip — no filenames, no progress, no entry errors — until submit. Operators conclude the upload is broken ("nothing happened after upload") and never get feedback.

## What Changes

- The import form gains `phx-change="validate"` with a no-op validate event that re-renders entries, progress, and entry errors on selection.
- Both upload configs gain `auto_upload: true` so files start uploading on selection with visible progress; submit consumes already-completed entries as today.
- No change to import semantics, validation rules, limits, or result reporting.

## Capabilities

### New Capabilities

None — interactivity fix on an existing surface.

### Modified Capabilities

- `agent-skills`: the "Import skills from folders and tar archives" requirement — the UI import acknowledges selection (listed entries with progress/errors) before submit. Import behavior and outcomes unchanged.

## Impact

- Affected code: `lib/agent_db_web/live/admin/skills_live.ex` (upload configs + validate event), `lib/agent_db_web/live/admin_components.ex` (form bindings only).
- No API/storage change. Unsubmitted auto-uploads leave temp files LiveView cleans on disconnect (standard).
- Out of scope: import validation changes (done in `fix-skill-import-macos-metadata`), console layout changes.
