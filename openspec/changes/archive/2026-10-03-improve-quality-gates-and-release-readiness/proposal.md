# Proposal

## Why

The library already meets the standards it documents — `mix compile --warnings-as-errors` and `mix format --check-formatted` both pass, the 78-file suite is green, and sixteen capability specs plus a boundary test describe how the code is supposed to be shaped — but nothing enforces any of it. Every one of those checks is a command a developer has to remember to type, which is why 96 modified and untracked files are sitting uncommitted on `main` right now with no reviewable history behind them. The same gap makes the library undeliverable: `README.md` declares MIT and the repository is `github.com/manhvu/agent_db`, yet there is no `LICENSE` file, `mix.exs` carries no package metadata, and nothing generates API documentation, so a consumer cannot install it from Hex or read its docs. Two smaller debts ride along: `Application.DataTransfer` is still 998 lines and the last module carrying several responsibilities at once, and the suite's own layout and output no longer match the codebase they verify.

## What Changes

- **Automated verification gates.** GitHub Actions runs on every push and pull request and fails the build on any of: `mix format --check-formatted`, `mix compile --warnings-as-errors`, and the full `mix test`. Credo (strict) and Dialyzer are added with a recorded, tracked baseline and `mix lint` / `mix lint:quick` aliases so the same gates are one command locally.
- **Distribution readiness.** Add the missing MIT `LICENSE` file that the README already claims. Add Hex package metadata, a `docs` configuration, and `ex_doc` so `mix hex.build` produces an installable package with the correct file set and `mix docs` generates API documentation for the public surface. Document the exact verification commands in the contributor-facing docs.
- **Decompose `Application.DataTransfer`.** Move the tar writer and payload digest into `AgentDb.Archive`, which already owns the read side of that container format, and extract manifest encoding and manifest validation into their own module. `DataTransfer` is left as orchestration over the sibling workflows. No public function signature, result shape, or archive format changes.
- **Test suite health.** Move the eight top-level test files into the capability directories whose code they cover. Make the project compile its own warnings-as-errors gate explicit so a project warning is a build failure rather than a line lost in output. Document the toolchain's dependency-metadata warning noise (about 18,000 lines emitted per run, none of it from project source) so a reviewer does not read it as project breakage. Audit the 43 files marked `async: false` and drop the flag only where a test provably shares no global state, recording the ones that must stay serial and why.

## Capabilities

### New Capabilities

- `delivery-quality`: the library's own quality gates and its distributability — automated verification of format, compilation, tests and static analysis on every change, plus a correctly licensed, correctly packaged, documented Hex release.

### Modified Capabilities

- None. The `DataTransfer` decomposition preserves every documented export/import behavior, and the test-suite work changes no runtime behavior. Both are implementation-level by project convention; the defects they fix are "the implementation does not match what already exists", not "the specification is wrong".

## Impact

- **CI:** new `.github/workflows/` running format, compile, test, Credo, and Dialyzer jobs against the supported Elixir/OTP matrix.
- **Build:** `mix.exs` gains `package` metadata, a `docs` configuration, `ex_doc`, `credo`, and `dialyxir` (dev/test only), and `mix lint` / `mix lint:quick` / `mix docs` aliases; new `.credo.exs` and a tracked lint/dialyzer baseline file; new `LICENSE`.
- **Code:** `lib/agent_db/application/data_transfer.ex`, `lib/agent_db/archive.ex`, a new manifest module beside them. Public `AgentDb` and `AgentDb.Application.DataTransfer` contracts unchanged.
- **Tests:** eight files relocated under `test/agent_db/` and `test/agent_db_web/`; new tests for the extracted archive writer and manifest validation; async-safety audit results recorded.
- **Docs:** `README.md` license section reconciled with the actual `LICENSE` file; contributor verification commands documented.
- **Not in scope:** committing the existing uncommitted working tree, and any change to runtime behavior, HTTP/WebSocket/MCP contracts, or the storage schema.