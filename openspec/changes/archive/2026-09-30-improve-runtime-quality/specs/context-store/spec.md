# Spec Delta

## MODIFIED Requirements

### Requirement: Async write acknowledgement

The store SHALL persist a document and all required durable background jobs for that write as one storage outcome before acknowledging success. The store SHALL acknowledge a successful write (`write/3`) before embedding generation and LLM summarization complete. Background jobs SHALL process embedding and summarization asynchronously. Readers SHALL see progressively enhanced content: content (L2) immediately, then abstract/overview (L0/L1) once generated, then vector searchability once embedded. If persistence or enqueueing any required job fails, the operation SHALL return an error and SHALL leave the prior document state, cache state, and queue state unchanged. A caller that has asked for the work to be completed before the write returns SHALL be told which of the three outcomes occurred: the work completed, the work failed, or the work is still outstanding. A failed job SHALL NOT be reported to a synchronous caller as though the work had completed.

#### Scenario: Write returns before embeddings ready
- **WHEN** a caller writes a document with asynchronous writes enabled
- **THEN** `:ok` is returned after the document and all required jobs are durably stored, before inference completes
- **AND** `read/1` returns the content immediately
- **AND** `abstract/1` and `overview/1` return fallback or generated content when ready
- **AND** `search/2` with `mode: :vector` includes the document once its embedding is indexed

#### Scenario: Caller-supplied layers omit unnecessary jobs
- **WHEN** a caller writes a document with a caller-supplied abstract or overview
- **THEN** the supplied layer is stored verbatim
- **AND** no job is enqueued to generate that supplied layer
- **AND** all other required jobs are durably stored before successful acknowledgement

#### Scenario: Enqueue failure rolls back the write outcome
- **WHEN** the store cannot enqueue any required job for a document write
- **THEN** `write/3` returns an error identifying the enqueue failure
- **AND** no partial job set remains
- **AND** a new document is absent, or an existing document retains its prior content and layers
- **AND** cached reads continue to agree with the durable document state

#### Scenario: Synchronous write reports completion honestly
- **WHEN** a caller writes with `async: false` and the background jobs complete
- **THEN** `write/3` returns `:ok`

#### Scenario: Synchronous write reports failure rather than success
- **WHEN** a caller writes with `async: false` and the background jobs for that document fail
- **THEN** `write/3` returns an error
- **AND** it does not report success as though the work had completed

#### Scenario: Synchronous write reports work still outstanding
- **WHEN** a caller writes with `async: false` and the background jobs have not finished within the wait
- **THEN** `write/3` reports that the work is still outstanding
- **AND** it does not report success
