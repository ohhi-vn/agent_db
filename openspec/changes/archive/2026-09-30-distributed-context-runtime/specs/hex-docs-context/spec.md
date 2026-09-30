# Spec Delta

## Purpose

Grounds agent answers in the Hex packages and versions the project actually uses, by indexing installed package docs with version-aware ranking.

## ADDED Requirements

### Requirement: Hex package discovery from the lockfile
The system SHALL discover Hex packages and their locked versions from the project's `mix.lock`, without network access. Each discovered package SHALL map to a docs subtree `viking://resources/hex/<package>/<version>/`. A project with no lockfile SHALL report that no Hex context is available rather than failing or guessing versions.

#### Scenario: Discover locked packages offline
- **WHEN** `mix.lock` pins `phoenix` to `1.8.0` and indexing runs with no network
- **THEN** the system records `phoenix` at `1.8.0` as the active version for ranking

#### Scenario: Missing lockfile reports empty Hex context
- **WHEN** no `mix.lock` exists
- **THEN** a Hex-scoped query returns `{:ok, []}` and indexing reports no packages found

### Requirement: Version-aware docs ingestion and ranking
The system SHALL ingest each locked package's README, HexDocs pages, and public API entries as ordinary searchable documents beneath its versioned subtree, and SHALL rank results for a query so that documents matching the locked version outrank documents for other versions of the same package. Every Hex result SHALL include its package name and version. Retrieval SHALL remain fully local once docs are cached.

#### Scenario: Locked version outranks other versions
- **WHEN** docs for `phoenix` `1.7`, `1.8`, and `1.9` are indexed but the lock pins `1.8`
- **AND** an agent searches for `Phoenix authentication`
- **THEN** `1.8` documents rank above `1.7` and `1.9` documents
- **AND** each result names its version

#### Scenario: Cached docs work offline
- **WHEN** Hex docs were previously ingested and the network is unavailable
- **THEN** Hex-scoped search still returns the cached versioned documents

### Requirement: Stale docs are refreshed on lock change
When `mix.lock` changes a package version, the next index run SHALL add the new version's subtree and SHALL leave the old version's subtree readable until explicitly removed. Indexing SHALL NOT duplicate an already-indexed package-version pair.

#### Scenario: Lock upgrade adds a version without losing the old one
- **WHEN** `phoenix` moves from `1.8.0` to `1.8.1` in `mix.lock` and indexing reruns
- **THEN** both `viking://resources/hex/phoenix/1.8.0/` and `.../1.8.1/` are readable
- **AND** ranking now prefers `1.8.1`
