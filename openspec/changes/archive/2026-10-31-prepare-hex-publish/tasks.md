# Tasks

## 1. Documentation warnings

- [x] 1.1 Identify and fix the `mix docs` warnings (hidden function references and `AgentDb.Runtime` reference), and verify `mix docs` prints no "warning:" lines.
- [x] 1.2 Run `mix docs` in CI-style (tee to file, grep for warning) and verify it exits clean.

## 2. mix.exs metadata

- [x] 2.1 Add `homepage_url` to the project config and verify `mix hex.build` metadata includes it.
- [x] 2.2 Pin `ex_doc` to a bounded version constraint (e.g. `~> 0.34`) and verify `mix deps.get` resolves.
- [x] 2.3 Add `secret_scan` configuration to the `package` block and verify `mix hex.build` succeeds.

## 3. Publish workflow

- [x] 3.1 Create `.github/workflows/publish.yml` triggered by `v*` tags and `workflow_dispatch`, gated on the verify workflow, using trusted publishing with `HEX_API_KEY` fallback, and verify the YAML parses.
- [x] 3.2 Document required repository secrets/permissions in the workflow comments and verify they are complete.

## 4. Publishing guide

- [x] 4.1 Add a publishing guide (version bump, tag, verify, publish, revert) and link it from `README.md`, and verify the documented commands match the workflow.
- [x] 4.2 Update `guides/SETUP.md` or `guides/README.md` index to include the publishing guide.

## 5. Verification

- [x] 5.1 Run `mix hex.build` and `tools/verify_package.exs`, and verify package identity is complete.
- [x] 5.2 Run `mix docs` with warnings-as-errors check and verify clean.
- [x] 5.3 Run `mix lint` and `mix test`, and verify all pass.