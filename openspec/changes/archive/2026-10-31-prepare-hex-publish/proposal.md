# Proposal

## Why

The project already builds a clean Hex package and verifies its contents, but nothing publishes it: there is no publish workflow, no secret-scanning configuration, and the documentation still builds with warnings (hidden internal references) that the delivery-quality gate already forbids. Following the Hex publishing guide, the project needs the remaining mix metadata, documentation, and CI wiring so a release can be cut and published to hex.pm without manual steps or leaked credentials.

## What Changes

- Complete `mix.exs` package metadata: add `homepage_url`, pin `ex_doc` to a released version, and add `secret_scan` ignore patterns for intentional secret-like fixtures (if any).
- Add a GitHub Actions publish workflow using trusted publishing (OIDC) with a documented `HEX_API_KEY` fallback, gated on the verify workflow passing.
- Make `mix docs` warning-free by resolving the remaining unresolved/hidden references, so the documented gate passes.
- Add a publishing guide (steps, versioning, revert) and point the README at it.
- Update `delivery-quality` spec to require a publishable release workflow, secret scanning, and warning-free docs.

No breaking changes to the public API or package identity.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `delivery-quality`: extend with requirements for a publishable release workflow, secret scanning, and warning-free documentation generation.

## Impact

- Affected code: `mix.exs`, `.github/workflows/publish.yml` (new), `guides/` (new publishing section), `README.md`, `openspec/specs/delivery-quality/spec.md`.
- APIs: none.
- Dependencies: `ex_doc` version constraint tightened.
- Systems: CI gains a publish job; Hex release process becomes documented and reproducible.