# llm-summarization Specification

## Purpose
Automatically generates caller-independent L0 abstracts and L1 overviews for documents using a local LLM, falling back to caller-supplied summaries when provided.

## Requirements

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

### Requirement: LLM model management
The store SHALL download and cache the configured summarization LLM (e.g., Qwen3-0.6B) on first use. The model SHALL run entirely locally via the configured ML backend (EXLA or EMLX/EMLXAxon). Model loading SHALL be lazy or eager (configurable). Inference SHALL use appropriate quantization (e.g., q4) for memory efficiency. A configured backend SHALL be applied to the loaded model. When the configured backend is unavailable or fails to initialize, the system SHALL fall back to EXLA CPU with a warning logged. A cached model SHALL load successfully and be retained for reuse. A download SHALL be written atomically, and a failed or interrupted download SHALL leave no file that later requests treat as a usable cached model. Because loading is lazy, a summary requested while the model is still loading SHALL be reported as loading and SHALL NOT be reported as a failure, and the caller SHALL be able to retry it. A request made while loading SHALL be given a bounded opportunity to complete before it is reported as loading, so that a request against an already-cached model does not have to be retried. The summarization model SHALL reach a loaded state once its own load completes, including when another model is loading concurrently: beginning a load for one model SHALL NOT leave the summarization model reporting as loading indefinitely. The format in which prompts are presented to the model SHALL be determined by configuration rather than fixed to one model architecture, so that configuring a different summarization model does not result in prompts being sent in a format that model was not built for. Generated summaries SHALL NOT contain the model's intermediate reasoning. A generation that yields no summary text once reasoning is removed SHALL be reported as an error and SHALL NOT be stored as an empty summary.

#### Scenario: Summarization model downloads on first use
- **WHEN** system starts with no cached LLM and summarization is needed
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent summarization uses cached model

#### Scenario: Summarization completes within acceptable latency
- **WHEN** LLM generates abstract/overview for typical document (<2000 tokens)
- **THEN** generation completes within configured timeout (e.g., <5s on CPU)

#### Scenario: Cached summarization model loads successfully
- **WHEN** the configured LLM is present in the local cache and a summary is requested
- **THEN** the model loads successfully and the request proceeds to inference rather than failing at load
- **AND** the loaded model is retained so a second request does not reload it

#### Scenario: Configured backend is applied to the summarization model
- **WHEN** a compute backend is configured
- **THEN** the loaded summarization model is placed on that backend
- **AND** the configuration is not silently ignored

#### Scenario: Interrupted LLM download does not poison the cache
- **WHEN** the summarization model download fails partway through
- **THEN** no file is left at the model's cache path
- **AND** a later request retries the download rather than failing against a truncated file

#### Scenario: A request made while the model is loading is reported as loading
- **WHEN** a summary is requested and the model is not yet loaded and a load is in progress
- **THEN** the request reports that the model is loading
- **AND** the request is not reported as a failure
- **AND** a later request, once the model is loaded, produces a summary

#### Scenario: A cached model does not force the caller to retry
- **WHEN** a summary is requested, the weights are already cached, and the load completes within the configured wait
- **THEN** the original request produces a summary
- **AND** the caller is not told to retry

#### Scenario: The summarization model loads while another model is loading
- **WHEN** a summary is requested and a load for another model is already in progress
- **THEN** the summarization model's own load proceeds independently
- **AND** the summarization model reaches a loaded state rather than continuing to report as loading
- **AND** a later summary request proceeds to inference instead of reporting the model as still loading

#### Scenario: The prompt format comes from configuration
- **WHEN** a summarization request is issued
- **THEN** the prompt is presented in the configured chat format
- **AND** the format used is not fixed to the architecture of any particular model

#### Scenario: A generated summary excludes the model's reasoning
- **WHEN** the model emits intermediate reasoning before its answer
- **THEN** the returned summary contains only the answer
- **AND** the stored abstract or overview does not contain the reasoning

#### Scenario: A generation with no answer after reasoning is reported as an error
- **WHEN** a generation produces reasoning but no summary text
- **THEN** the request reports an error rather than returning an empty summary
- **AND** no empty value is written to the document

#### Scenario: Backend falls back to EXLA on EMLX failure
- **WHEN** `ml_backend` is `:emlx` or `:auto` on macOS but EMLX/EMLXAxon fails to load
- **THEN** a warning is logged
- **AND** the LLM loads via EXLA CPU backend instead
- **AND** summarization continues to function

### Requirement: Summarization idempotency and retry
If a summarization job fails (model error, timeout, OOM), it SHALL be retried with exponential backoff. Re-processing the same document content SHALL produce deterministic output (same prompt, same model, same parameters = same result). Failed jobs SHALL not block other summarization work. The retry budget SHALL be reserved for failures that can succeed on retry: a job deferred because its model is still loading SHALL NOT consume an attempt, and SHALL be rescheduled rather than counted toward exhaustion.

#### Scenario: Failed summarization retries
- **WHEN** a summarization job fails with transient error
- **THEN** job is re-queued with backoff
- **AND** other summarization jobs continue processing

#### Scenario: Same content produces same summary
- **WHEN** two documents with identical content are written at different times
- **THEN** their auto-generated abstracts and overviews are identical

#### Scenario: Waiting for a model does not exhaust the retry budget
- **WHEN** a summarization job is deferred repeatedly because the model is still loading
- **THEN** the job remains eligible for processing and is not marked failed
- **AND** its retry attempts are not consumed by the deferrals
- **AND** the job completes once the model is loaded
### Requirement: Summarization survives restart
Generated summaries SHALL persist in SQLite and be available after restart without re-generation. The background job queue SHALL recover pending summarization jobs after restart.

#### Scenario: Summaries survive restart
- **WHEN** documents with auto-generated summaries exist, application restarts
- **THEN** `abstract/1` and `overview/1` return the previously generated summaries
- **AND** no re-generation occurs for already-summarized documents

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
