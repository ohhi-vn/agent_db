# Tasks

## 1. Licensing and package identity

- [x] 1.1 Add the MIT `LICENSE` file at the repository root with the copyright holder taken from the repository owner (`Manh Van Vu`, matching the `github.com/manhvu/agent_db` remote); verify the file exists, states MIT, and names the holder
- [x] 1.2 Point `README.md`'s license section at `LICENSE` instead of restating terms in prose alone; verify the README names MIT and links the file
- [x] 1.3 Add `package` metadata to `mix.exs` — `licenses: ["MIT"]`, `source_url`, `links` to the repository, and an explicit `files:` list of `lib`, `config`, `priv/static`, `mix.exs`, `README.md`, `LICENSE`, `docs`; verify `mix hex.build` succeeds with no missing-field warning
- [x] 1.4 Inspect the built tarball and assert its contents: `lib/`, `config/`, `priv/static/`, `docs/`, `README.md`, `LICENSE`, and `mix.exs` present; `models/`, `data/`, `_build/`, `deps/`, `assets/`, `bench/`, `test/`, `tools/`, `openspec/`, and `._*` sidecars absent; verify by listing the archive entries, not by reading `mix.exs`
- [x] 1.5 Confirm the package's declared identity is complete (name, version, description, license, links, `elixir` requirement) by inspecting the built package's metadata; verify no required field is empty

## 2. Generated API documentation

- [x] 2.1 Add `ex_doc` as a dev/test-only dependency and a `docs` configuration in `mix.exs` with `main: "readme"`, `extras:` for the three guides plus `docs/agents.md`, and `groups_for_modules` mirroring the capability layout; verify `mix deps.get` succeeds and `mix docs` produces `doc/`
- [x] 2.2 Mark `AgentDbWeb.Layouts.Live` and `AgentDbWeb.ErrorView` as `@moduledoc false` (rendering internals), consistent with `Store.*`, `URI`, `RuntimeContext`, and `ML.ModelDownload`; verify neither appears in the generated reference and `mix compile --warnings-as-errors` still passes
- [x] 2.3 Run `mix docs` and fix every warning and unresolved reference it reports; verify a clean build with no warnings

## 3. Reproducible local verification commands

- [x] 3.1 Add `mix lint` (format check, Credo strict, Dialyzer) and `mix lint:quick` (format check, Credo strict) aliases to `mix.exs`, plus a `mix docs` alias; verify each alias runs the intended sub-tasks in order
- [x] 3.2 Add `.tool-versions` pinning the Elixir and OTP versions the project supports (currently Elixir 1.20 on OTP 29 locally); verify a tool that reads it resolves those versions
- [x] 3.3 Declare `test/support/` ignored in the project's `:test` configuration (`test_ignore_filters`) so `mix test` stops warning that `ml_fakes.ex`, `provider_fakes.ex`, `scratch.ex`, and `storage_contract.ex` match no test filter; verify the warning is gone and `mix test path/to/one_test.exs` still works via `test_helper.exs`' `Code.require_file`

## 4. Static analysis with a reasoned baseline

- [x] 4.1 Add `credo` and `dialyxir` as dev/test-only dependencies, configure the Dialyzer PLT path and `plt_add_apps: [:mix, :ex_unit, :emlx, :emlx_axon]` so the optional model backends are not reported as unknown; verify `mix dialyzer` builds a PLT and runs against the unchanged tree
- [x] 4.2 Write `.credo.exs` selecting the check set for this codebase in strict mode; verify `mix credo --strict` runs and reports findings
- [x] 4.3 Triage Credo findings: fix the cheap and genuinely wrong ones, and disable only tolerated checks in `.credo.exs` with a comment giving the reason; verify `mix credo --strict` is clean and every disabled check has a reason
- [x] 4.4 Triage Dialyzer findings: fix any that indicate a real contract or behavior risk, and record the rest in a checked-in `.dialyzer_ignore.exs` with one commented entry per pattern; verify `mix dialyzer` reports clean and each ignored pattern carries a reason
- [x] 4.5 Re-run `mix dialyzer` and `mix credo --strict` after the fixes and confirm no entry was added to either baseline to make a gate pass; verify both baselines are smaller than or equal to their initial measured state

## 5. Automated verification in CI

- [x] 5.1 Add `.github/workflows/verify.yml` with a matrix of the oldest supported OTP and the OTP maintainers run locally (OTP 27 and 29), triggered on push and pull request; verify the workflow is syntactically valid and both legs are defined
- [x] 5.2 Add the ordered steps to each leg: `mix deps.get`, `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix test`; verify a deliberately introduced project warning fails the compile step and names the file and line
- [x] 5.3 Add the slow static-analysis step (`mix lint`) to the primary leg only; verify it runs Dialyzer and Credo and fails on a finding absent from the baselines
- [ ] 5.4 Cache `~/.hex`, `_build`, and the Dialyzer PLT keyed on `mix.lock` — **implemented**, its verification (a second run reusing the cache) needs a GitHub Actions run and is the one item not checked off here
- [x] 5.5 Add `package` and `docs` jobs that run `mix hex.build` and `mix docs` and assert the tarball's contents per task 1.4; verify the job fails when a local artifact is present in the tarball
- [x] 5.6 Confirm the suite needs no model download or inference provider key under CI (the `test/support/*_fakes.ex` providers answer); verify a full CI-equivalent run passes with no `AGENT_DB_*` inference configuration set

## 6. Decompose `Application.DataTransfer`

- [x] 6.1 Add `AgentDb.Archive.build/2` (members → `{:ok, binary}`, preserving the temp-file path `:erl_tar.create` requires) and `Archive.write/3` (path, members, compression choice), moving the `:erl_tar.create` calls out of `DataTransfer`; verify `test/agent_db/archive_test.exs` and `test/agent_db/data_transfer_test.exs` pass with the new functions covered by new tests
- [x] 6.2 Add `AgentDb.Archive.digest/1` for the lowercase-hex SHA-256 the manifest uses, replacing `DataTransfer`'s private digest; verify export/import round-trip tests still assert the same checksums
- [x] 6.3 Add `AgentDb.Application.DataTransfer.Manifest` holding manifest encoding (version, scope, counts, digests) and manifest/member validation, moving the roughly sixty validation clauses out of `DataTransfer`; verify every existing `data_transfer_test.exs` case passes unchanged, with new tests covering the extracted validation paths
- [x] 6.4 Delete the superseded private functions from `DataTransfer` and confirm it now reads as orchestration (limits, messages, scope normalization, collection, payload application); verify `mix compile --warnings-as-errors` reports no unused-function warnings and the full suite is green
- [x] 6.5 Check `test/agent_db/boundaries_test.exs` against the new module and add `Application.DataTransfer.Manifest` to the asserted core set if warranted; verify the boundary test passes and that the manifest module names no provider

## 7. Test suite health

- [x] 7.1 Relocate the seven misplaced test files to mirror the `lib/` paths they exercise: `test/agent_db/subscriptions_test.exs`, `test/agent_db/code_index_test.exs`, `test/agent_db/hex_docs_test.exs`, `test/agent_db/runtime_context_test.exs`, `test/agent_db/adapters/inference_providers_test.exs`, `test/agent_db/retrieval_stages_test.exs`, `test/agent_db_web/channel_subscriptions_test.exs`; verify `mix test` passes and each file still runs standalone
- [x] 7.2 Check every path reference to the moved files — `test_helper.exs` requires, `docs/`, and any CI or script naming them — and update it; verify no reference to the old paths remains
- [x] 7.3 Investigate the observed `** (MatchError) … {:error, :enoent}` in `Kernel.ParallelCompiler.require_file/2` while loading `test/agent_db/runtime_test.exs`: attempt reproduction on a local filesystem and check whether the CI runner (Linux, local disk) ever hits it; verify the outcome is recorded as identified, or as observed-once on the external volume with the AppleDouble sidecars as context
- [x] 7.4 Classify all 43 `async: false` test files by what global state they touch (SQLite/exqlite connections, supervised ETS tables, `Application` env mutation, filesystem writes outside `System.tmp_dir!`, global registries, endpoint/session state); verify the classification is written down per file
- [x] 7.5 Flip to `async: true` only the files the classification proves share no global state, running each flipped file repeatedly to confirm stability; verify the full suite is green and record which files stayed serial and why

## 8. Documentation and final verification

- [x] 8.1 Document the verification commands (`mix lint`, `mix lint:quick`, `mix compile --force --warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix docs`, `mix hex.build`) in the contributor-facing docs, and note that dependency-metadata warnings during a cold build are not project warnings; verify each documented command runs as written
- [x] 8.2 Reconcile `docs/SETUP.md` and `README.md` with the new release reality (license file, package build, generated docs); verify no documented behavior contradicts the implementation
- [x] 8.3 Run the full gate locally — `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix test`, `mix credo --strict`, `mix dialyzer`, `mix docs`, `mix hex.build` — and confirm each passes; verify the tarball assertion from task 1.4 one final time
- [x] 8.4 Confirm nothing outside the file moves and the two new modules changed runtime behavior: diff the public function surface of `AgentDb`, `AgentDb.Application.DataTransfer`, and `AgentDb.Archive`, and verify no signature, result shape, or reason tuple changed