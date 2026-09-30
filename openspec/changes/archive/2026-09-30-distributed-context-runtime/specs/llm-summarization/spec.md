# Spec Delta

## MODIFIED Requirements

### Requirement: Automatic L0 abstract generation
The store SHALL generate a concise abstract (L0) for every document using the configured summarization provider (local LLM by default, see `inference-providers` capability) when the caller does not supply one. The generated abstract SHALL be a single sentence or short paragraph capturing the document's core point. Generated abstracts SHALL be stored alongside caller-supplied ones and returned by `abstract/1` calls.

#### Scenario: Auto-abstract generated when caller omits L0
- **WHEN** a document is written with content but no `:abstract` option
- **THEN** write returns `:ok` immediately
- **AND** a background job generates the abstract via LLM
- **AND** subsequent `abstract/1` calls return the LLM-generated text

#### Scenario: Caller-supplied L0 takes precedence
- **WHEN** a document is written with explicit `:abstract` option
- **THEN** the caller-supplied abstract is stored and returned
- **AND** no LLM call is made for abstract generation

#### Scenario: Abstract regeneration on content update
- **WHEN** an existing document's content is updated via write
- **THEN** a new abstract is generated (unless caller supplies one)
- **AND** the stored abstract is replaced with the new version

### Requirement: Automatic L1 overview generation
The store SHALL generate a structured overview (L1) for every document using the configured summarization provider (local LLM by default, see `inference-providers` capability) when the caller does not supply one. The overview SHALL be a multi-sentence summary covering key points, suitable for quick scanning. Generated overviews SHALL be stored and returned by `overview/1` calls.

#### Scenario: Auto-overview generated when caller omits L1
- **WHEN** a document is written with content but no `:overview` option
- **THEN** write returns `:ok` immediately
- **AND** a background job generates the overview via LLM
- **AND** subsequent `overview/1` calls return the LLM-generated text

#### Scenario: Caller-supplied L1 takes precedence
- **WHEN** a document is written with explicit `:overview` option
- **THEN** the caller-supplied overview is stored and returned
- **AND** no LLM call is made for overview generation
