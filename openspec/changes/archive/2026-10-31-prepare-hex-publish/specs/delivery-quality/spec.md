# delivery-quality Specification

## Purpose
Keep the library's own quality gates and the artifact it publishes trustworthy, and make a release to hex.pm reproducible from CI.

## ADDED Requirements

### Requirement: A release can be published from CI

The system SHALL provide an automated publish workflow that runs only after the full verification workflow passes, and that publishes the package and its documentation to Hex without an interactive prompt. The workflow SHALL prefer trusted publishing (OIDC) and SHALL support a documented `HEX_API_KEY` fallback for environments where trusted publishing is unavailable. The workflow SHALL be triggered by a version tag (or an explicit manual dispatch) and SHALL not publish on ordinary pushes to the default branch.

#### Scenario: Tagged release publishes

- **WHEN** a version tag is pushed and verification passes
- **THEN** the package and documentation are published to Hex without manual confirmation
- **AND** the publish job does not run for ordinary pushes to the default branch

#### Scenario: Trusted publishing is preferred

- **WHEN** the publish workflow runs on a supported CI provider
- **THEN** it uses OIDC trusted publishing when available
- **AND** falls back to `HEX_API_KEY` only when trusted publishing is unavailable

### Requirement: Published packages are scanned for secrets

The system SHALL configure secret scanning for the published package. Paths that deliberately ship secret-like values (such as test fixtures) SHALL be declared in `:secret_scan` ignore patterns in `mix.exs`, and the configuration SHALL be present in the package metadata. A release SHALL NOT be blocked by the scan, but leaked credentials SHALL be reported to the package owners as described by Hex.

#### Scenario: Secret scan configuration is declared

- **WHEN** the package metadata is inspected
- **THEN** a `:secret_scan` entry is present (possibly with an empty ignore list)
- **AND** the configuration is valid for Hex 2.5.2 or later

### Requirement: Release metadata is complete for publication

The system SHALL declare the metadata a Hex release requires beyond the package identity: a homepage URL pointing at the project site or repository, and a pinned (non-wildcard) `ex_doc` development dependency. The release SHALL be cut from a version tag whose value matches the `:version` in `mix.exs`.

#### Scenario: Homepage URL is declared

- **WHEN** the package metadata is inspected
- **THEN** `homepage_url` is present and non-empty

#### Scenario: ex_doc is pinned

- **WHEN** the dependencies are inspected
- **THEN** `ex_doc` is declared with a bounded version constraint rather than `>= 0.0.0`

### Requirement: Publishing is documented

The system SHALL document the release process — version bump, tag, verification, publish, and revert — in a guide, and the README SHALL link to it. The documented steps SHALL match the CI workflow and the `mix hex.publish` contract.

#### Scenario: A maintainer can cut a release from the docs

- **WHEN** a maintainer follows the publishing guide
- **THEN** they can produce a tagged, verified, published release
- **AND** the steps agree with the CI workflow