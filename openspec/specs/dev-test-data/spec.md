# dev-test-data Specification

## Purpose
Lets developers and tests populate a fresh AgentDb store with one deterministic demo dataset for local exploration, console and API demos, and repeatable test fixtures.

## Requirements

### Requirement: Deterministic demo dataset via API
The system SHALL provide a seed operation that builds the same demo dataset on every run: documents under the demo prefix, typed memories, one session committed into the tree, one demo skill, and code-index entries for the demo project. Re-running the seed SHALL converge without duplication.

#### Scenario: First seed populates all dataset kinds
- **WHEN** the seed runs against an empty store
- **THEN** documents exist under the demo prefix and are readable, memories recall by type, the committed session reads back, the demo skill reads back, and code-index entries are discoverable

#### Scenario: Re-seed is idempotent
- **WHEN** the seed runs twice with the same options
- **THEN** the second run succeeds and URIs resolve to one active value each with no duplicate documents, memories, or sessions

#### Scenario: Keyword paths work without inference
- **WHEN** the seed runs while models are unavailable or still loading
- **THEN** the seed succeeds and keyword search, find, and grep reach the seeded content immediately

### Requirement: Mix task with human and machine output
The system SHALL provide `mix agent_db.seed` wrapping the seed operation. It SHALL support `--json` printing the outcome as JSON to stdout, SHALL keep human-readable output without the flag, and SHALL exit non-zero with the reason on stderr on failure.

#### Scenario: Seed as JSON from shell
- **WHEN** a developer runs `mix agent_db.seed --json` on an empty dev store
- **THEN** stdout contains the seeded counts and URIs as JSON

#### Scenario: Failure exits non-zero
- **WHEN** the seed is refused (for example non-empty store without override)
- **THEN** the task exits non-zero and stderr names the reason

### Requirement: Unsafe seeds are refused by default
The system SHALL refuse to seed a non-empty store unless an explicit override is given, SHALL refuse in production unless explicitly allowed, and SHALL never delete data outside the seed scope during a scoped reset.

#### Scenario: Non-empty store needs explicit override
- **WHEN** the seed runs against a store that already holds data without `--force` or `--clean`
- **THEN** it is refused naming the non-empty store and nothing is written

#### Scenario: Force merges and clean resets only the seed scope
- **WHEN** the seed runs with `--force`
- **THEN** missing seed URIs are created and present ones revised in place with nothing deleted
- **WHEN** the seed runs with `--clean`
- **THEN** only the seed scope is removed before re-seeding and data outside that scope survives

#### Scenario: Production needs explicit opt-in
- **WHEN** the seed runs with `Mix.env() == :prod` without `--allow-prod`
- **THEN** it is refused naming the production guard and nothing is written

### Requirement: Seed is prefix-scoped and self-describing
The system SHALL seed under a default demo prefix and SHALL accept a prefix override. The outcome SHALL report what was created per kind and the prefix used so tests and scripts can assert on it.

#### Scenario: Custom prefix isolates the dataset
- **WHEN** the seed runs with a custom prefix override
- **THEN** all demo documents and the committed session live under that prefix and the default prefix is untouched

#### Scenario: Outcome reports per-kind counts
- **WHEN** the seed completes
- **THEN** the result states counts for documents, memories, sessions, skills, and indexed files plus the prefix used
