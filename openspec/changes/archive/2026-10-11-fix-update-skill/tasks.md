# Tasks

## 1. Reproduce and diagnose

- [x] 1.1 Reproduce same-name skill update via `{:uploads}`, `{:archive}`, and `{:path}` sources for one user and record the failing surface, steps, and observed vs expected status/state; verify by a failing script or test output showing the update gap.
- [x] 1.2 Locate the owning layer for the reproduced failure (`Skills.Source` grouping/normalization, `Adapters.SQLite.replace_skill` transaction, or `Cache`/notify consistency) and record the exact module/function and violated invariant; verify by a trace from failing surface to owning layer with no behavior edit yet.

## 2. Fix at the owning layer

- [x] 2.1 Subscribe the document editor to store changes and refresh its stored sections on relevant events without clobbering an unsaved draft (dirty shows a notice; removed doc preserves the draft with a notice); verify by a LiveView test opening a skill file, re-importing it, and seeing the new content without manual reload.
- [x] 2.2 Reload admin pages immediately on the first change event after mount by initializing `last_reload_ms` relative to the monotonic clock; verify by a LiveView test showing a same-mount change reflected without waiting for the deferred coalesced reload.
- [x] 2.3 Verify the healthy replace path still holds (sibling skill/user isolation, failed-replacement preservation, `:replaced` reporting, cache/queue/event consistency); verify by the existing `skills_test.exs`, `source_test.exs`, `import_skills_test.exs`, and admin realtime cases passing.

## 3. Regression and acceptance

- [x] 3.1 Fold the reproduction into permanent regression tests (editor refresh incl. dirty-draft and removed-doc cases; admin first-event immediate reload) alongside the related coverage the fix touches; verify by the new tests plus `mix test test/agent_db_web/live/` passing.
- [x] 3.2 Run the adjacent suites covering the touched path (documents/status/admin console, subscriptions) and fix any regression the change introduced; verify by the selected suites passing with no unrelated failures left unexplained.
- [x] 3.3 Validate planning artifacts and change state via `openspec validate fix-update-skill` (plus `openspec status --change fix-update-skill`) and resolve any findings; verify by validation reporting no errors for the change.
