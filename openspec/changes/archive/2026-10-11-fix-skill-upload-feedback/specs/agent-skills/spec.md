# Spec Delta

## MODIFIED Requirements

### Requirement: Import skills from folders and tar archives
The system SHALL allow an operator to import Agent Skills through both the admin UI and a local Mix task, from either a local folder or a TAR or gzip-compressed TAR archive. A source SHALL contain either one skill directory with a `SKILL.md` at its root, or a collection directory/archive containing one or more immediate skill directories, each with a `SKILL.md`. An archive MAY include one common top-level wrapper directory. The operator SHALL select a user ID, and each imported skill SHALL be stored below `viking://user/{user_id}/skills/{skill_name}`. The UI and CLI SHALL use the same import behavior and report the outcome for every skill. The UI SHALL acknowledge a file or folder selection before submit by listing the selected entries with their progress and any entry errors.

#### Scenario: Import one folder skill from the CLI
- **WHEN** an operator imports a skill directory containing `SKILL.md` and nested reference files with the Mix task for user `alice`
- **THEN** the skill is available below `viking://user/alice/skills/{skill_name}`
- **AND** its files retain their relative paths and contents

#### Scenario: Import a collection archive from the UI
- **WHEN** an operator uploads a TAR archive containing multiple skill directories, each with `SKILL.md`, and selects user `alice`
- **THEN** every skill is imported below `viking://user/alice/skills/`
- **AND** the UI reports the result for each skill

#### Scenario: Accept a single enclosing archive directory
- **WHEN** a valid TAR archive contains all skill entries beneath one common top-level directory
- **THEN** the importer recognizes the skills beneath that wrapper and imports them using the same destination layout

#### Scenario: Selection lists entries before submit
- **WHEN** an operator selects a skills folder or archive in the UI form
- **THEN** the form lists the selected entries with progress without requiring submit
- **AND** an entry the upload config rejects is reported at the form before submit
