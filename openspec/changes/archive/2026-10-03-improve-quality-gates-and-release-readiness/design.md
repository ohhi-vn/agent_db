# Design

## Context

See `proposal.md` for motivation. Constraints and measured current state that shape the approach:

**Verification today is manual, and it passes.** `mix compile --force --warnings-as-errors` compiles 79 project modules with zero warnings in both `dev` and `test`. `mix format --check-formatted` is clean. `mix test` is green across 78 test files in 78.3s. `test/agent_db/boundaries_test.exs` asserts the layering by reading reference graphs rather than trusting structure. There is no `.github/` directory, no `package`/docs configuration in `mix.exs`, no `credo`/`dialyxir`/`ex_doc` in the 56-entry `mix.lock`, and no aliases.

**Warning output is dominated by non-project noise.** A cold `mix test` emits 18,368 `found quoted keyword` warnings, every one attributed to `nofile` — 328 dependency-metadata evaluations × 56 locked dependencies. A warm `MIX_ENV=test mix compile --force` and a warm `mix run --no-start` both emit zero, which locates the noise in dependency compilation, not in project source. `mix test` also warns that `test/support/{ml_fakes,provider_fakes,scratch,storage_contract}.ex` match no test filter, because they are `Code.require_file`'d from `test_helper.exs` rather than compiled.

**Distribution gaps are concrete.** `origin` is `github.com/manhvu/agent_db`; `README.md` ends with "License: MIT"; no `LICENSE` file exists. `models/` is tracked in git while `data/` is ignored, so Hex's default file selection would ship model binaries — the package needs an explicit `files:` list. `priv/static` holds assets the LiveView surface serves at runtime and must be in the package; `assets/`, `bench/`, `openspec/`, `test/`, `tools/` should not be.

**Module conventions are already established.** `@moduledoc false` marks internal modules (`Store.*`, `RuntimeContext`, `URI`, `ML.ModelDownload`), which is what ExDoc already omits; only `AgentDbWeb.Layouts.Live` and `AgentDbWeb.ErrorView` lack any `@moduledoc`. Nested modules follow their owner (`ML.ModelManager.Backend`, `ML.ModelManager.State`, `Web.Live.AdminComponents`), so a manifest module nests under its workflow.

**`Application.DataTransfer` (998 lines) still holds four responsibilities.** Public surface: `limits/0`, `export_payload/1`, `parse_archive/1`, `export/2`, `import/1`, `message/1`. Internals: scope normalization and collection of documents/memories/sessions; JSON encoding, manifest encoding, SHA-256 digests and entry/size checks; the tar writer (`:erl_tar.create` twice — `build_tar/1` through a temp file for in-memory payloads, `write_tar/5` for path targets); roughly sixty validation clauses; and payload application through the sibling workflows. `AgentDb.Archive` already owns the read side (`list/3`, `extract/2`, `declared_size/1`, `plain_tar/2`) with the entry-type refusal, but no writer, so the container format currently has a reader and a writer in different vocabularies.

**Tests mirror `lib/` exactly where they are nested, and stop doing so at the top level.** `test/agent_db/…` mirrors `lib/agent_db/…` and `test/agent_db_test.exs` correctly mirrors `lib/agent_db.ex`. Eight files break the rule: `channel_subscriptions_test.exs` (subject `AgentDbWeb.Channel`), `code_index_test.exs`, `hex_docs_test.exs`, `runtime_context_test.exs`, `inference_providers_test.exs`, `retrieval_stages_test.exs`, `subscriptions_test.exs`. 43 of 78 test files declare `async: false`, and the suite's split is 0.8s async against 77.4s sync.

**One unexplained observation.** The first `mix test` run on this machine failed with `** (MatchError) … {:error, :enoent}` inside `Kernel.ParallelCompiler.require_file/2` while loading `test/agent_db/runtime_test.exs`; the immediately following run passed. The working tree lives on `/Volumes/ManhExt1T`, and `._*` AppleDouble sidecars are present throughout `lib/` and `config/`, so the volume is not the boot disk.

## Goals / Non-Goals

**Goals:**
- One definition of each gate, runnable both locally and by CI, that fails on a format violation, a project compiler warning, a failing test, or an unaccounted static-analysis finding.
- A package that builds, declares complete identity, carries its license, excludes local artifacts, and is proven by inspecting a built tarball rather than by intent.
- `DataTransfer` left as orchestration, with container-format concerns in `AgentDb.Archive` and manifest concerns in their own module.
- A suite whose layout mirrors `lib/`, whose output attributes warnings to their origin, and whose serial/async choices are recorded rather than inherited.

**Non-Goals:**
- Not committing the existing uncommitted working tree, and not changing what that work does.
- No change to runtime behavior, public function signatures, result shapes, the storage schema, or the HTTP/WebSocket/MCP contracts. Existing capability specs stay as they are.
- No weakening of a check to make it pass: no disabled formatter rules, no `--no-warnings-as-errors`, no global warning suppression.
- No custom baseline tooling. Tolerated findings live in the tools' own tracked configuration files.
- No automated publish pipeline and no long-lived registry credentials in this repository; releasing is a documented manual step.
- No attempt to eliminate the toolchain's dependency-metadata warnings; they are attributed, not suppressed.

## Decisions

### 1. Gates are Mix aliases, and CI invokes those aliases
Add to `mix.exs`: `lint` = format check, Credo strict, Dialyzer; `lint:quick` = the same minus Dialyzer, whose PLT analysis dominates the runtime; `docs` = `ex_doc`. The warnings-as-errors compile gate stays an explicit `mix compile --force --warnings-as-errors` step rather than `elixirc_options: [warnings_as_errors: true]`.

That last choice is deliberate and evidence-driven: the measured 18,368 warnings all originate during dependency compilation, and a project-wide setting risks turning toolchain noise into a build failure on a cold machine, which is exactly the failure mode the spec forbids. An explicit compile step compiles only project files once dependencies are built, so the diagnostics it reports are the project's own.

*Alternatives:* CI-only inline commands (rejected — the command a developer runs and the command CI runs would drift, which is how gates become decorative); a custom `mix verify` Mix task wrapping everything (rejected — a module to maintain for what aliases express, and its failure output would have to re-parse sub-task output); pre-commit hooks (rejected — unenforceable across contributors and platforms, and it duplicates the alias).

### 2. Tolerated findings live in each tool's own tracked configuration, with a reason
`.credo.exs` selects the check set for this codebase in strict mode; a check that is tolerated rather than satisfied is disabled there with a comment giving the reason. Dialyzer findings are tolerated only through a checked-in `.dialyzer_ignore.exs` with one commented entry per pattern. Both files are reviewed in the ordinary diff, so a new entry is visible where it is added rather than in a generated artifact.

Starting point is measurement, not a guess: run each tool on the current tree, fix what is cheap and genuinely wrong, and record what remains with a reason. The baseline is expected to shrink; an entry may only be removed once the code behind it is fixed.

*Alternatives:* a generated baseline file compared by a custom script (rejected — a tool to maintain a tool's output, and it hides the reason in a diff nobody reads); running Credo non-strict (rejected — the strict set is the point); `mix credo --mute-exit-status` in CI (rejected — a gate that cannot fail is not a gate).

### 3. CI is Linux-only, minimal, and cached on `mix.lock`
One workflow with two matrix legs (oldest supported OTP and the OTP maintainers run locally — the working copy is Elixir 1.20.4 on OTP 29), plus a `docs` and `package` job. Steps, in order: `mix deps.get`, `mix lint:quick`-equivalent format check, `mix compile --force --warnings-as-errors`, `mix test`, then the slow static analysis (`mix lint`) on the primary leg only, then `mix docs` and `mix hex.build` with the tarball's contents asserted. Cache `~/.hex`, `_build`, and the Dialyzer PLT, keyed on `mix.lock` — the dependency cache is what keeps the measured 328-evaluation warning storm off every run after the first.

Tests are CPU-only and use the existing `test/support/*_fakes.ex` providers, so no model download occurs in CI; the workflow sets no inference provider key and lets the fakes answer.

*Alternatives:* a macOS leg (rejected — doubles the slowest part for a platform difference the suite does not exercise); running Credo and Dialyzer on both legs (rejected — identical findings, double the minutes); `continue-on-error` with a reporting job (rejected — that is a dashboard, not a gate).

### 4. The package declares its file set explicitly, and the tarball is inspected
`mix.exs` gains `package` with `licenses: ["MIT"]`, `files:` limited to `lib`, `config`, `priv/static`, `mix.exs`, `README.md`, `LICENSE`, and `docs`, and `links` to the repository. Verification is `mix hex.build` followed by listing the tarball's entries and asserting the absence of `models/`, `data/`, `_build/`, `openspec/`, `bench/`, and `._*` sidecars. The absence assertion is the point: `models/` is tracked and not ignored, so the default selection would publish binaries.

`LICENSE` is the standard MIT text with the copyright line matching the repository owner, and `README.md`'s license section points at the file instead of restating terms.

*Alternatives:* gitignore the model cache as well and rely on default selection (rejected — it hides the problem rather than declaring intent, and the package then depends on ignore rules staying correct); omitting `docs/` from the package (rejected — it is the reference a consumer needs alongside the generated API docs).

### 5. Documentation is generated from doc comments, with internal modules excluded by the existing convention
Add `ex_doc` (dev/test only) and a `docs` config with `main: "readme"`, `extras:` for the three guides plus `docs/agents.md`, and `groups_for_modules` mirroring the capability layout. ExDoc already omits `@moduledoc false`, which the codebase uses for `Store.*`, `RuntimeContext`, `URI`, and `ML.ModelDownload`; the two undocumented web modules (`Layouts.Live`, `ErrorView`) are marked `@moduledoc false` rather than given invented docs, because they are rendering internals.

*Alternatives:* documenting those two modules instead (rejected — a doc comment written to satisfy a doc build is worse than an honest internal marker); publishing docs from CI (rejected — needs hosting credentials; out of scope).

### 6. `AgentDb.Archive` gains the writer and the digest
`AgentDb.Archive` gains `build/2` (members → `{:ok, binary}`, keeping the temp-file dance `:erl_tar.create` requires) and `write/3` (path, members, compression choice), plus `digest/1` for the lowercase-hex SHA-256 the manifest uses. The module's stated purpose already covers both directions of a bounded container; a writer living in a workflow module means the format's rules are written twice in two vocabularies, which is the exact drift the module was created to stop.

`DataTransfer` keeps the manifest's *meaning* — version, scope, counts, digests, per-entry validation — in a new nested `AgentDb.Application.DataTransfer.Manifest`, matching the `ML.ModelManager.Backend` nesting precedent, while `DataTransfer` retains orchestration: limits, messages, scope normalization, collection, and application of the payload through the sibling workflows.

*Alternatives:* leaving the writer where it is (rejected — half a codec); a top-level `AgentDb.Transfer.Manifest` (rejected — introduces a namespace root for one module); moving payload application into the manifest module (rejected — that is workflow orchestration, not format).

### 7. Tests mirror `lib/` paths, and support files stop being flagged
Each of the seven misplaced files moves to the path mirroring the module it exercises (`test/agent_db/subscriptions_test.exs`, `test/agent_db/code_index_test.exs`, `test/agent_db/hex_docs_test.exs`, `test/agent_db/runtime_context_test.exs`, `test/agent_db/adapters/inference_providers_test.exs`, `test/agent_db/retrieval_stages_test.exs`, `test/agent_db_web/channel_subscriptions_test.exs`). `test/agent_db_test.exs` stays where it is: it mirrors `lib/agent_db.ex`.

The `test/support/*.ex` load warning is silenced by declaring the directory ignored in the project's `:test` configuration (`test_ignore_filters`), keeping the files as `Code.require_file`'d modules — which is what lets a single-file `mix test path` run work — rather than renaming them.

*Alternatives:* renaming support files to `.exs` (rejected — they would still match no test pattern and still warn); moving support into `elixirc_paths` (rejected — breaks the documented single-file run and the reason the choice was made).

### 8. The async audit changes only what it can prove
Every `async: false` file is classified by what it touches: SQLite/exqlite connections, named ETS tables owned by the supervision tree, `Application` env mutation, filesystem writes outside `System.tmp_dir!`, global registries, and endpoint/session state. Only a file that touches none of these is flipped to `async: true` and re-run repeatedly to confirm stability. The rest stay serial, and the reason each stays is recorded in the design's follow-up notes rather than as 43 new comments.

*Alternatives:* flipping everything and investigating failures (rejected — converts a known-good suite into a flaky one to save time); dropping the audit (rejected — 0.8s of 78s running in parallel is a real cost that deserves a recorded answer, even if the answer is "most of these must stay serial").

### 9. The load failure is investigated before anything is built around it
The `{:error, :enoent}` load failure gets a reproduction attempt on a local filesystem and a check of whether the CI runner (Linux, local disk) ever hits it, before any mitigation is written. If it does not reproduce and CI stays clean, it is recorded as observed once on an external volume, with the AppleDouble sidecars as the supporting context. No retry, sleep, or serialization is introduced on its account.

*Alternatives:* wrapping the suite in a retry (rejected — hides a cause that has not been identified); pinning the affected test file to run alone (rejected — the failure was in the loader, not in that file's behavior).

## Risks / Trade-offs

- [The tree is dirty: 96 modified/untracked files, including the whole previous change] → The first CI run verifies that state, not a reviewed commit history; results are reported as "current working tree" until the tree is committed. No task commits it (out of scope), and no task assumes a clean baseline.
- [Dialyzer over EXLA/Nx/Phoenix may surface a large number of real findings] → The PLT is built once and cached; findings are triaged as fix-now (spec/behaviour risk, e.g. a callback that can never match) versus tolerate-with-reason; a large honest count in `.dialyzer_ignore.exs` is an acceptable landing state, an unexplained one is not. Optional apps (`:emlx`, `:emlx_axon`) are added to the PLT so their absence is not reported as unknown.
- [Credo strict on a codebase with no prior Credo history could be noisy] → Measure first, configure the check set for this codebase, and keep the tolerated list small and reasoned; the same applies to the format and compile gates, which already pass and must stay passing.
- [CI cold builds download precompiled XLA and compile EXLA/Nx, so the first run is slow] → Cache `_build` and `~/.hex` on `mix.lock`; the slow analysis runs on one leg only; a documented time budget is recorded in the workflow.
- [Restructuring `DataTransfer` touches archive and manifest validation, which is security-relevant] → Public functions, result shapes, reason tuples, and the on-disk format are unchanged; `test/agent_db/data_transfer_test.exs` and the archive tests are the contract, and new tests cover the extracted writer and manifest paths before the old private functions are deleted.
- [`mix hex.build` shipping the wrong files is discovered only at publish time if unverified] → The tarball's entry list is asserted in the `package` job and locally; the assertion covers both what must be present and what must not.
- [Moving test files breaks any command that names them] → `test/support/*_fakes.ex` are required by path from `test_helper.exs`, not by test path; `test/mix/tasks/*` and docs that reference test file names are checked before the moves land.
- [Recording async decisions without changing most of them leaves the suite slow] → Accepted deliberately: correctness of the suite outranks its wall-clock, and the recorded reasons make a future change informed rather than blind.
- [A `LICENSE` naming a copyright holder is a factual claim] → The holder is taken from the repository owner/remote and confirmed in review; if it cannot be confirmed, the license file ships with a placeholder that blocks publish rather than asserting the wrong holder.
- [`mix test` intermittently fails to load a test file, unattributed] → Established by measurement, not assumed: the failure is `:epp` refusing to open a path inside Mix's parallel loader, names a different file each time, occurs for files under `test/` and for at least one path under the system temporary directory, and is not reproducible by reading those files (10,000 sequential and 1,960 sixteen-way concurrent reads, plus 8,000 reads outside the BEAM, all clean). Neither `--max-cases 1` nor `--max-requires 1` prevents it, so it is not a parallelism setting; AppleDouble sidecars are excluded because `Path.wildcard` never matches a dotfile. An earlier hypothesis that the exFAT/USB volume was the cause is **not** supported once a failure appeared under the local temporary directory. No cause is known, so nothing in the repository works around it; it is documented in `docs/SETUP.md` with its evidence, and CI on Linux with a local disk is the environment the gate is written for.
- [Test-file moves change ExUnit ordering, which can surface latent isolation bugs] → Observed: an `on_exit` callback in the shared storage-contract helper called into `AgentDb.Supervisor` after another file's teardown had stopped the application, failing a test that had already passed. The helper's own moduledoc says the application may already be stopped, so the guard belongs there; `restart_when_free/2` now checks the supervisor is alive. Any future reordering should be treated as a possible trigger for latent ordering assumptions rather than as a mechanical move.

## Migration Plan

1. **Additive first:** add `LICENSE`, `ex_doc`, `credo`, `dialyxir`, `package`/`docs` config, `.credo.exs`, `.dialyzer_ignore.exs`, aliases, `.tool-versions`, and the workflow. Nothing existing changes behavior, so a revert is deleting those files.
2. **Measure, then baseline:** run Credo and Dialyzer against the unchanged tree; fix what is cheap and correct; record the rest with reasons. No gate is enabled in a failing state — each job turns green before the next is added.
3. **Refactor behind green tests:** move the archive writer and digest into `AgentDb.Archive`, add `Application.DataTransfer.Manifest`, then delete the old private functions. The suite must be green before and after each step.
4. **Test hygiene last:** relocate the seven files, silence the support-file warning, then run the async classification. Relocations and `async: true` flips land as separate commits' worth of work so a suite failure is attributable.
5. **Rollback:** every step is additive or a pure move. Reverting the workflow and `mix.exs` block restores today's manual process; reverting the refactor restores the single-module `DataTransfer` with no format or data implication; the extra `LICENSE` and config files are inert.

## Open Questions

- Which dependency emits the quoted-keyword warnings during compilation is not identified, only localized to dependency metadata. Confirming it may allow a narrower attribution note in the docs; it changes no gate and no task.
- Whether OTP 28 belongs in the matrix alongside 27 and 29 depends on which versions the project intends to support; the workflow expresses the matrix in one place, so adding or removing a leg is a one-line change.
- Which individual `priv/static` build outputs are needed at runtime (as opposed to only in development) is confirmed by reading the built tarball during implementation; decision 4 fixes the shape of the set — sources under `assets/`, `bench/`, `test/`, `tools/`, and `openspec/` stay out, `lib`, `config`, `priv/static`, `docs`, `mix.exs`, `README.md`, and `LICENSE` stay in.