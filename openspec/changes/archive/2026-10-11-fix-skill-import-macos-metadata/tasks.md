# Tasks

## 1. Skip OS metadata in Source loaders

- [x] 1.1 Set aside `._*` and `.DS_Store` entries in all three loaders (disk walk, archive members, browser uploads) before counting/normalization, with docs updated; verify by importing the reporter's shape (folder with `SKILL.md` + binary `._SKILL.md`) succeeding with only real files stored.
- [x] 1.2 Keep refusal behavior for metadata-only sources and for all existing refusal reasons; verify by the existing `source_test.exs` refusal cases plus a metadata-only case passing.

## 2. Regression and acceptance

- [x] 2.1 Add regression tests (disk/archive/uploads skip, budget/layout exclusion, metadata-only refusal) and verify by `mix test test/agent_db/skills/source_test.exs test/agent_db/skills_test.exs test/mix/tasks/import_skills_test.exs` passing.
- [x] 2.2 Run adjacent suites and `openspec validate fix-skill-import-macos-metadata`; verify by green suites and valid change.
