# llm-summarization Specification

## Purpose
Automatically generates caller-independent L0 abstracts and L1 overviews for documents using a local LLM, falling back to caller-supplied summaries when provided.

## Requirements

### Requirement: Automatic L0 abstract generation
The store SHALL generate a concise abstract (L0) for every document using a local LLM when the caller does not supply one. The generated abstract SHALL be a single sentence or short paragraph capturing the document's core point. Generated abstracts SHALL be stored alongside caller-supplied ones and returned by `abstract/1` calls.

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
The store SHALL generate a structured overview (L1) for every document using a local LLM when the caller does not supply one. The overview SHALL be a multi-sentence summary covering key points, suitable for quick scanning. Generated overviews SHALL be stored and returned by `overview/1` calls.

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
The store SHALL download and cache the configured summarization LLM (e.g., Phi-3-mini-4k-instruct) on first use. The model SHALL run entirely locally via Bumblebee/EXLA. Model loading SHALL be lazy or eager (configurable). Inference SHALL use appropriate quantization (e.g., q4) for memory efficiency.

#### Scenario: Summarization model downloads on first use
- **WHEN** system starts with no cached LLM and summarization is needed
- **THEN** model is downloaded from configured URL to local cache
- **AND** subsequent summarization uses cached model

#### Scenario: Summarization completes within acceptable latency
- **WHEN** LLM generates abstract/overview for typical document (<2000 tokens)
- **THEN** generation completes within configured timeout (e.g., <5s on CPU)

### Requirement: Summarization idempotency and retry
If a summarization job fails (model error, timeout, OOM), it SHALL be retried with exponential backoff. Re-processing the same document content SHALL produce deterministic output (same prompt, same model, same parameters = same result). Failed jobs SHALL not block other summarization work.

#### Scenario: Failed summarization retries
- **WHEN** a summarization job fails with transient error
- **THEN** job is re-queued with backoff
- **AND** other summarization jobs continue processing

#### Scenario: Same content produces same summary
- **WHEN** two documents with identical content are written at different times
- **THEN** their auto-generated abstracts and overviews are identical

### Requirement: Summarization survives restart
Generated summaries SHALL persist in SQLite and be available after restart without re-generation. The background job queue SHALL recover pending summarization jobs after restart.

#### Scenario: Summaries survive restart
- **WHEN** documents with auto-generated summaries exist, application restarts
- **THEN** `abstract/1` and `overview/1` return the previously generated summaries
- **AND** no re-generation occurs for already-summarized documents
