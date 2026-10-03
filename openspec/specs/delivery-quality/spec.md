# delivery-quality Specification

## Purpose
Keep the library's own quality gates and the artifact it publishes trustworthy: every change is checked automatically before it merges, static-analysis findings are either fixed or explicitly accounted for, and what consumers receive is licensed, installable as a package, and documented from the code itself.

## Requirements

### Requirement: Every change is verified automatically

The system SHALL verify every change automatically, before it reaches the default branch, by running all of the following against the exact commit under review: source formatted as the project's formatter defines it; the application compiled with compiler warnings treated as errors; the complete test suite passing; and static analysis reporting no finding that is not accounted for. A check that does not pass SHALL block the change, and there SHALL be no path by which a commit arrives on the default branch without all four having run against that commit. The verification SHALL report each check separately, so a failure names which gate failed rather than presenting an undifferentiated failure.

#### Scenario: Pull request is verified gate by gate

- **WHEN** a pull request is opened or a new commit is pushed to it
- **THEN** the formatting, compilation, test, and static-analysis checks each run and report their own result
- **AND** any check that fails is reported as blocking

#### Scenario: A compiler warning is introduced

- **WHEN** a change introduces a warning in the project's own source
- **THEN** the compilation check fails
- **AND** the failure names the file and line of that warning

#### Scenario: Nothing reaches the default branch unverified

- **WHEN** a commit appears on the default branch
- **THEN** all four checks ran against that exact commit and passed
- **AND** a commit whose checks did not pass is not present on that branch

### Requirement: Static analysis findings are fixed or explicitly accounted for

The system SHALL run static analysis — code-quality checks in strict mode and type-consistency analysis — as part of the automatic verification, and SHALL record their findings in a baseline file kept with the code. A finding that is not in the baseline SHALL fail verification. A finding SHALL be added to the baseline only alongside a recorded reason for tolerating it, and the baseline SHALL be permitted to shrink but never to grow silently: removing an entry requires the underlying code to have been fixed. The same checks SHALL be runnable locally through a single documented command, so that a failure a developer would meet in verification is reproducible before it is pushed.

#### Scenario: The local command reproduces the gate

- **WHEN** a developer runs the documented local verification command
- **THEN** it runs the same checks the automatic verification runs
- **AND** a finding it reports is a finding the automatic verification would also report

#### Scenario: A new finding is not silently absorbed

- **WHEN** static analysis reports a finding that is not in the baseline
- **THEN** verification fails
- **AND** it passes only once the code is fixed or the finding is baselined with a recorded reason

#### Scenario: The baseline does not grow without justification

- **WHEN** a change adds entries to the baseline
- **THEN** each added entry carries a reason for tolerating that finding
- **AND** no entry is removed unless the code it refers to has been fixed

### Requirement: Verification is reproducible and its output is readable

The system SHALL document the exact commands a developer or reviewer runs to verify a change, and SHALL compile the project's own source with warnings treated as errors so that a warning in project source cannot pass unnoticed. Where verification output contains warnings originating outside the project's source — from dependency metadata or from the toolchain's compilation of third-party code — the system SHALL identify them as such and keep them from obscuring a warning in project source. A verification run that fails while loading a source file rather than while running a test SHALL report the file it could not load, never a silent or partial pass.

#### Scenario: The documented commands are the real checks

- **WHEN** a reviewer follows the documented verification commands
- **THEN** the same checks the automatic verification runs are executed
- **AND** a warning in project source fails the run rather than being printed and ignored

#### Scenario: Dependency warnings are distinguishable from project warnings

- **WHEN** verification output contains warnings emitted by dependency metadata rather than by the project's source
- **THEN** those warnings are identified as not originating in the project
- **AND** a warning in project source remains visible and failing among them

#### Scenario: A source file that cannot be loaded is reported

- **WHEN** a verification run fails while loading a source file instead of while executing a test
- **THEN** the failure names the file that could not be loaded
- **AND** the run does not report a pass

### Requirement: The release is licensed and installable as a package

The system SHALL build a package that a consumer can add as a dependency, declaring the identity such a consumer needs: name, version, description, license, source and documentation links, and the supported Elixir requirement. The package SHALL contain the files needed to compile, run, and serve the library — library source, configuration, static assets, documentation, and the license file — and SHALL exclude compiled output, local data and model caches, downloaded binaries, and planning or change history. The set of files the package declares SHALL be verified by building the package and inspecting it, not assumed from intent. The repository SHALL contain the license file the package and the documentation declare, and the documentation's license statement SHALL point at that file instead of restating terms only in prose.

#### Scenario: A consumer installs and starts the package

- **WHEN** a consumer adds the published package as a dependency of their own project
- **THEN** it resolves, compiles, and starts
- **AND** the static assets and configuration it needs are present in the package

#### Scenario: Local artifacts stay out of the package

- **WHEN** the package is built from a working tree that also holds local data, model caches, and downloaded binaries
- **THEN** none of those appear in the package

#### Scenario: Declared identity is complete

- **WHEN** the package's declared metadata is inspected
- **THEN** it declares name, version, description, license, links, and the supported Elixir requirement, with no required field missing

#### Scenario: The terms of use are discoverable from the repository

- **WHEN** someone reads the repository to decide whether they may use the library
- **THEN** a license file is present at the repository root and the documentation's license statement points at it
- **AND** the terms in that file are the terms the documentation names

### Requirement: API documentation is generated from the code

The system SHALL generate API documentation from the library's public modules and their doc comments, so that the reference describes the code as it is rather than as it was written. Modules marked as internal SHALL be excluded from the generated reference. Documentation generation SHALL complete without warnings and without unresolved references, and a change that breaks either SHALL fail the same verification as any other failure.

#### Scenario: Documentation builds cleanly

- **WHEN** documentation is generated
- **THEN** it completes without warnings or unresolved references
- **AND** every public module's doc comment appears in the output

#### Scenario: Internal modules are excluded

- **WHEN** documentation is generated
- **THEN** modules marked as internal do not appear in the reference

#### Scenario: Documentation drift fails verification

- **WHEN** a change would leave the generated documentation unbuildable or a doc reference unresolved
- **THEN** verification fails rather than publishing a stale or broken reference