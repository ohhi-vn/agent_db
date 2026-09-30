# Tasks

## 1. Transfer core (codec + validation)

- [x] 1.1 Add `AgentDb.Application.DataTransfer` with `limits/0`, `export_payload/1` builder and `parse_archive/1` validator (manifest v1, URI + UTF-8 + entry/byte checks, `:erl_tar` table-then-extract with gzip magic detection) and verify `mix test test/agent_db/data_transfer_test.exs` covers round-trip encode/decode plus traversal, corrupt, oversize, and bad-manifest refusals leaving state untouched
- [x] 1.2 Add `error_message/1` human-readable reasons for every refusal and verify unit test asserts each reason renders a non-empty sentence

## 2. Store workflows + facade

- [x] 2.1 Implement export walk via `Runtime.storage()` reads (scope or full, documents with caller-supplied L0/L1, memory provenance + history, sessions in seq order) writing `.tar`/`.tar.gz` by extension and verify export of a seeded store produces a valid tar whose manifest counts match
- [x] 2.2 Implement import merge via `Documents.write/3`, `Memories.remember/3` (+ history), and session restore (skip identical id, preserve id when free, skip-and-report on conflicting id), emitting the same notifications/jobs as native writes, and verify import into an empty store restores reads, recalls, and session order
- [x] 2.3 Expose `AgentDb.export_data/1-2` and `AgentDb.import_data/1-2` (path or `{:archive, binary}` sources, `scope:` opt on export) with `export_data_error_message/1` and verify facade round-trip test plus re-import convergence (second import identical state, unrelated URIs untouched)
- [x] 2.4 Verify imported content behaves natively: keyword search, find/grep, and PubSub notifications fire for restored URIs (add to `data_transfer_test.exs` and verify it passes)

## 3. CLI

- [x] 3.1 Add `mix agent_db.export_data PATH [--scope URI] [--json]` following `import_skills` patterns and verify `mix agent_db.export_data /tmp/x.tar.gz --json` prints JSON and missing-scope exits non-zero with reason on stderr
- [x] 3.2 Add `mix agent_db.import_data PATH [--json]` and verify `mix agent_db.import_data /tmp/x.tar.gz --json` restores content and corrupt input exits non-zero without writing

## 4. Integration + docs

- [x] 4.1 Add CLI tests in `test/mix/tasks/` for both tasks (JSON + human output, failure exits) and verify `mix test test/mix/tasks/export_data_test.exs test/mix/tasks/import_data_test.exs` passes
- [x] 4.2 Run full suite `mix test` and `openspec validate --change export-data-tar-import --strict` and verify both are green
- [x] 4.3 Document export/import in README (tar handoff section) and verify `grep -n export_data README.md` shows the new section
