# Spec Delta — context-store

## ADDED Requirements

### Requirement: Storage write path isolates callback failures
The system SHALL isolate a failure raised inside a single storage write callback to that caller's error result and SHALL NOT terminate the shared writer nor affect subsequent writes. A statement handle acquired for a write SHALL be released on every outcome, including bind, step, and callback errors.

#### Scenario: Bad payload fails one write, not the writer
- **WHEN** a caller writes a document whose job payload cannot be encoded
- **THEN** that write returns a classified `{:error, reason}`
- **AND** a subsequent valid write succeeds without restart

#### Scenario: Contended write retries within a bound
- **WHEN** the store is contended and the database reports busy
- **THEN** the write waits and retries within a bounded timeout rather than failing immediately
- **AND** a write that still cannot proceed returns a retryable classified error, not a crash

#### Scenario: Failed claim does not crash the writer
- **WHEN** claiming a background job encounters a storage error
- **THEN** the claim returns a classified `{:error, reason}` and the worker retries later
- **AND** the shared writer remains available for other calls

### Requirement: Bounded content inspection and listing reads
The system SHALL apply the caller's `limit` inside storage for content inspection (`grep`), memory lists, and session lists, and SHALL NOT materialize unbounded rows or document blobs before truncating. Removal of a subtree and recent-error reads SHALL NOT scan entire in-memory tables row by row on the hot path.

#### Scenario: Large grep honors limit without loading everything
- **WHEN** thousands of lines match a content query with `limit: 50`
- **THEN** at most 50 results are returned
- **AND** the store transfers only a bounded candidate set from storage, not every matching blob

#### Scenario: Memory and session lists are bounded
- **WHEN** many memories or sessions exist and the caller lists them
- **THEN** the result is bounded and ordered deterministically
- **AND** the store does not load the full table to answer the call

### Requirement: Bounded durable retry with attempt preservation
The system SHALL bound retries for poison-pill jobs: a job that fails for a reason that cannot succeed on retry SHALL be marked failed after its budget, and a restart SHALL preserve attempt history rather than resetting it to zero. A job deferred only because a model is still loading SHALL NOT consume the retry budget. A queued job whose kind is unknown SHALL NOT accumulate silently as permanent pending work; it SHALL be classified and surfaced as failed with its reason.

#### Scenario: Poison pill stops after its budget across restarts
- **WHEN** a job fails deterministically on every attempt and the application restarts
- **THEN** the job resumes with its prior attempt count intact
- **AND** it is marked failed once the budget is exhausted rather than retried forever

#### Scenario: Deferred job keeps its budget
- **WHEN** a job is deferred repeatedly because its model is still loading
- **THEN** its attempt count does not advance
- **AND** it remains eligible for execution once the model is ready

#### Scenario: Unknown job kind does not sit pending forever
- **WHEN** a queued row carries an unrecognized kind
- **THEN** claiming it returns a classified failure identifying the kind problem
- **AND** the row does not remain pending indefinitely
