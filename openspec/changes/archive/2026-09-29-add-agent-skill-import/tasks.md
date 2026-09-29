# Tasks

## 1. Shared import and storage workflow

- [x] 1.1 Implement bounded normalization and validation for directory, browser-upload, TAR, and gzip-TAR sources; verify unit tests cover accepted layouts, invalid paths, links, duplicate entries, invalid UTF-8, and size limits.
- [x] 1.2 Add an atomic per-skill replacement operation to the storage contract and SQLite adapter, including old URI-state cleanup, new document writes, and background-job enqueueing; verify storage contract tests prove replacement and rollback preserve tree/vector/job consistency.
- [x] 1.3 Add the shared skill-import application workflow and `AgentDb` facade entry point, including validation-before-mutation and post-commit cache invalidation; verify tests cover new imports, complete replacement, validation failures, cached reads, and per-skill partial results.

## 2. Import entry points

- [x] 2.1 Add admin UI uploads for a directory or TAR archive and a required user ID, with per-skill results and errors; verify LiveView tests cover both upload forms and replacement/error reporting.
- [x] 2.2 Add a Mix task accepting a directory or TAR path and user ID, invoking the shared workflow and returning failure when any skill fails; verify task tests cover directory/archive imports, output, and exit status.

## 3. Documentation and integration verification

- [x] 3.1 Document the accepted source layouts, UI flow, Mix task invocation, text-file and size limits, and full replacement behavior; verify examples match the task help and UI labels.
- [x] 3.2 Run the complete test suite and project formatting checks; verify all tests and `mix format --check-formatted` pass.
