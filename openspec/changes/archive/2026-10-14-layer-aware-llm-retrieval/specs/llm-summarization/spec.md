# Spec Delta

## ADDED Requirements

### Requirement: Generated abstract is bounded to one sentence
The generated abstract (L0) SHALL be bounded to a single sentence. When the summarization provider emits more than one sentence, the stored abstract SHALL be reduced to its first sentence rather than stored whole, so that an abstract stays a one-line decision input rather than a second overview. The reduction SHALL NOT report an error, and a generation that yields no sentence SHALL continue to be reported as an error and stored as nothing, per the existing empty-summary rule.

#### Scenario: Provider emits several sentences for an abstract
- **WHEN** a document is written without a caller-supplied abstract
- **AND** the configured summarization provider answers with several sentences
- **THEN** the stored abstract holds the first sentence only
- **AND** `abstract/1` returns that single sentence on one line

#### Scenario: Abstract reduction does not fail the job
- **WHEN** a generated abstract is reduced to its first sentence
- **THEN** the summarization job reports success
- **AND** the reduction is not reported to the caller as a failure

### Requirement: Generated overview is bounded to five sentences
The generated overview (L1) SHALL be bounded to five sentences. When the summarization provider emits more, the stored overview SHALL be reduced to its first five sentences, so that scanning an overview costs a bounded amount of reading regardless of how the provider answered.

#### Scenario: Provider emits more than five sentences for an overview
- **WHEN** a document is written without a caller-supplied overview
- **AND** the configured summarization provider answers with more than five sentences
- **THEN** the stored overview holds at most five sentences
- **AND** `overview/1` returns that bounded text

#### Scenario: Overview is not reduced when already within budget
- **WHEN** a generated overview is already five sentences or fewer
- **THEN** it is stored exactly as generated

### Requirement: Generated layers prefer distinguishing terms
The summarization prompt SHALL ask for what distinguishes a document from other documents in the same store — its specific subject, identifiers, decisions, or scope — rather than a description that would fit any document. A generated layer SHALL retain the document's own specific terms where its content states them, and SHALL NOT replace them with generic phrasing of the same idea.

#### Scenario: Abstract names the document's own subject
- **WHEN** two documents about different subjects are summarized
- **THEN** each abstract names its own subject
- **AND** neither abstract reads as a sentence that fits both documents

#### Scenario: Overview retains the document's identifiers
- **WHEN** a document whose body names specific identifiers or decisions is summarized
- **THEN** the generated overview carries those identifiers
- **AND** they are not replaced with generic phrasing of the same idea

### Requirement: Summarization sees the document's frontmatter identity
When a document opens with a leading YAML frontmatter block, the store SHALL pass that block's identity fields to the summarization request as context, so a generated layer states what the document is for rather than summarizing its metadata. The frontmatter block itself SHALL NOT be summarized as though it were body text.

#### Scenario: Skill layer states purpose, not frontmatter
- **WHEN** a document whose frontmatter carries `name:` and `description:` fields is summarized without a caller-supplied layer
- **THEN** the generated layer reflects what the `description:` says the document is for
- **AND** the generated layer does not read as a transcription of the frontmatter block

#### Scenario: Document without frontmatter is summarized from its body
- **WHEN** a document with no leading frontmatter block is summarized
- **THEN** the generated layers describe its body
- **AND** no identity context is invented for it

### Requirement: Layer bounds and identity travel with the job
The bounds and frontmatter context a summarization prompt uses SHALL be carried in the job's own payload rather than held in state beside the queue, so a job recovered after a restart produces the layer it would have produced before. A payload written before this requirement applied SHALL be summarized from the content alone rather than refused.

#### Scenario: Recovered job reproduces its layer
- **WHEN** a summarization job is recovered after a restart and reprocesses the same content
- **THEN** the layer it stores matches the layer that would have been stored without the restart

#### Scenario: Job predating the identity context still summarizes
- **WHEN** a job whose payload carries no identity context is processed
- **THEN** its layers are generated from the content alone
- **AND** the job is not refused for the missing context
