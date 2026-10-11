# Spec Delta — agent-skills

## ADDED Requirements

### Requirement: Installed-skill inventory listing
The system SHALL provide an inventory of installed skills across users, each entry carrying skill name, owner `user_id`, full skill URI (`viking://user/{user_id}/skills/{skill_name}`), file count, enabled status, and group tag. The inventory SHALL support paged reads (default 50 per page) and name/URI substring search with optional owner scope. Listing SHALL be read-only and SHALL NOT alter store state.

#### Scenario: List all skills across users
- **WHEN** skills exist for users `alice` and `bob` and a caller lists the inventory
- **THEN** every installed skill is returned with its name, owner, full URI, file count, status, and group

#### Scenario: Search skills by name substring
- **WHEN** a caller searches the inventory for "review" and matching and non-matching skills exist
- **THEN** only skills whose name or URI contains "review" are returned

#### Scenario: Empty inventory returns empty list
- **WHEN** no skills are installed and a caller lists the inventory
- **THEN** an empty list is returned rather than an error

### Requirement: Skill enable and disable blocked-from-use
The system SHALL persist an enabled/disabled state per skill root, defaulting to enabled. A disabled skill SHALL stay readable and editable but be excluded from search, recall, and default listings unless explicitly included.

#### Scenario: Disable blocks skill from search but keeps it readable
- **WHEN** an operator disables `viking://user/alice/skills/review` and a caller searches a term that skill contains
- **THEN** that skill's URIs are excluded from search results
- **AND** a direct read of a file in that skill still returns its content

#### Scenario: Re-enable restores skill to search
- **WHEN** an operator re-enables a previously disabled skill after its exclusion was observed
- **THEN** a subsequent search for a term that skill contains returns that skill's URIs again

#### Scenario: Existing skills default to enabled
- **WHEN** skills installed before this change are listed after migration
- **THEN** each reads as enabled unless explicitly disabled since

### Requirement: Skill grouping by owner plus custom tag
The system SHALL report each skill's owner as its default group and persist one custom group tag per skill root. Tags SHALL be at most 64 chars (letters, digits, dash, underscore, slash).

#### Scenario: Assign a custom group to a skill
- **WHEN** an operator assigns group "reviewers" to `viking://user/alice/skills/review`
- **THEN** the inventory reports owner `alice` and custom group "reviewers" for that skill

#### Scenario: Replace preserves status and group
- **WHEN** an operator re-imports a valid skill over a disabled, grouped skill
- **THEN** the replaced skill keeps its disabled status and custom group tag
- **AND** its files are replaced whole per existing replace semantics

#### Scenario: Invalid group tag is refused
- **WHEN** an operator assigns an empty-overlong or illegal-character group tag
- **THEN** the assignment is refused with a classified error and the prior tag is unchanged

### Requirement: Bulk skill enable, disable, and grouping
The system SHALL apply enable, disable, and group-tag assignment to a caller-supplied set of skill URIs (one group, one owner, or one filtered search result) as one bulk action, answering per-skill outcomes plus summary counts. A bulk action SHALL NOT stop at the first failure; every reachable skill SHALL be attempted. A refused bulk set SHALL leave all skill state unchanged.

#### Scenario: Bulk-disable one owner's skills
- **WHEN** an operator bulk-disables all skills for user `alice` while `bob`'s skills exist
- **THEN** every `alice` skill reads as disabled, every `bob` skill is unchanged, and per-skill outcomes plus counts are answered

#### Scenario: Partial bulk failure reports per skill
- **WHEN** a bulk group assignment reaches skills where one fails
- **THEN** each successful skill carries the new tag and the result identifies the failed skill without claiming it succeeded
