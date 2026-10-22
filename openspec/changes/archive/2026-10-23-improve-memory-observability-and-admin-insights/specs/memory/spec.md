# Spec Delta

## MODIFIED Requirements

### Requirement: Recording and revising a memory
The store SHALL record a memory's value, and SHALL treat the URI as the identity of the thing being asserted. Recording a memory at a URI that already holds a memory SHALL revise that URI's memory in place rather than produce a second one. Recording at a URI that holds no memory SHALL create it. The store SHALL NOT reject a revision on the grounds that a memory already exists there. A caller MAY record a memory as a candidate; a candidate SHALL be stored but SHALL be excluded from default recall until explicitly promoted, and promoting a candidate SHALL make it the active assertion at its URI. Rejecting a candidate SHALL remove it without a trace. Whether a record is held as a candidate SHALL be determined by the URI being written and the caller's own instruction, and SHALL NOT be determined by a value that happens to exist at some other URI; recording a value that is already held elsewhere SHALL NOT by itself make the new record invisible to recall.

#### Scenario: First record creates the memory
- **WHEN** a caller records `prefers Elixir over Go` at `viking://user/memories/preferences/language`
- **THEN** reading that URI returns `prefers Elixir over Go`

#### Scenario: Re-recording revises rather than duplicates
- **WHEN** a memory exists at `viking://user/memories/preferences/language`
- **AND** the caller records a different value at that same URI
- **THEN** reading that URI returns the newly recorded value
- **AND** exactly one memory exists at that URI

#### Scenario: Distinct URIs coexist
- **WHEN** a caller records one memory at `viking://user/memories/entities/repos/agent_db`
- **AND** records another at `viking://user/memories/events/released-1-2`
- **THEN** both memories are retrievable
- **AND** neither is reported as superseding the other

#### Scenario: The same value at a different URI is retrievable
- **WHEN** a caller records `prefers Elixir over Go` at `viking://user/memories/preferences/language`
- **AND** the caller records that same value at `viking://user/memories/entities/repos/agent_db`
- **THEN** recalling `viking://user/memories/entities/repos/agent_db` returns that memory
- **AND** it is not held as a candidate awaiting promotion

#### Scenario: Re-recording the same value at the same URI does not accumulate candidates
- **WHEN** a caller records a value at a URI twice
- **THEN** exactly one memory exists at that URI
- **AND** no candidate is left waiting at that URI

#### Scenario: Candidate is hidden until promoted
- **WHEN** a caller records a memory as a candidate
- **THEN** default recall does not return it
- **AND** promoting it makes it the active assertion at its URI

#### Scenario: Rejected candidate leaves no trace
- **WHEN** a caller rejects a candidate memory
- **THEN** no value, provenance, or history remains at that URI

#### Scenario: A candidate does not overwrite the active belief's document
- **WHEN** a memory is active at a URI
- **AND** the caller records a different value at that same URI as a candidate
- **THEN** reading that URI returns the active memory's value
- **AND** the candidate's value is not readable as the document at that URI

### Requirement: Recalling memories
The store SHALL return stored memories on request, individually by URI, as a subtree, or filtered by type, and SHALL support restricting a recall to entries matching a term. A recall SHALL report only currently-active memories by default. When a recall returns more than one memory without a term query, the store SHALL order results by descending confidence. When a recall includes a term query, the store SHALL order the already-filtered active set by a deterministic blend of confidence and semantic similarity to the query, with exact-substring matches boosted and stale, rarely-surfaced memories penalized; filtering (scope, type, active-only) SHALL precede ranking. Recalling a memory SHALL record that it was surfaced. A recall that matches nothing SHALL return an empty result rather than an error. When embeddings are unavailable or the query dim does not match stored vectors, recall SHALL fall back to confidence ordering and report backfill needed rather than failing. Each returned memory SHALL report the type derived from that memory's own URI, independent of the scope the recall was issued against. A recall SHALL accept a `:top_k` bound, SHALL apply it in storage, and SHALL report whether the returned set was truncated by that bound. A recall issued against a malformed URI SHALL report an error rather than raising.

#### Scenario: Recall by type
- **WHEN** memories of type `events` and type `preferences` both exist
- **AND** the caller recalls by type `events`
- **THEN** only memories of type `events` are returned

#### Scenario: Recall excludes superseded memories
- **WHEN** a memory at a URI was revised, leaving its predecessor superseded
- **AND** the caller recalls that URI
- **THEN** the revised memory is returned
- **AND** the superseded predecessor is not returned

#### Scenario: Recall orders by confidence
- **WHEN** two memories of the same type have differing confidence
- **THEN** the higher-confidence memory is returned before the lower-confidence one

#### Scenario: Recall of a term that matches nothing
- **WHEN** the caller recalls with a term matching no stored memory
- **THEN** an empty result is returned
- **AND** no error is reported

#### Scenario: Paraphrased query finds the firmly-held fact
- **WHEN** one memory reads `prefers Elixir over Go` with high confidence and another reads `tried Go once` with low confidence
- **AND** the caller recalls with a paraphrased term like `likes Elixir`
- **THEN** the high-confidence relevant memory ranks first despite imperfect phrasing overlap

#### Scenario: Embedding unavailable falls back to confidence
- **WHEN** a term recall is issued while embeddings are unavailable or dim-mismatched
- **THEN** results remain confidence-ordered
- **AND** the recall does not fail
- **AND** backfill need is reported

#### Scenario: Stale memories rank below fresh ones
- **WHEN** two otherwise equally scoring memories exist and one has not been surfaced for a long time
- **THEN** the stale memory ranks below the fresh one

#### Scenario: Recall records surfacing
- **WHEN** a caller recalls a memory
- **THEN** a later inspection of that memory reports that it was surfaced

#### Scenario: Each memory reports its own type
- **WHEN** memories of several types exist beneath the memories root
- **AND** the caller recalls the whole memories root
- **THEN** each returned memory reports the type derived from its own URI
- **AND** no returned memory reports an absent type

#### Scenario: Recall is bounded
- **WHEN** many memories exist and the caller recalls with `top_k: 10`
- **THEN** at most 10 memories are returned
- **AND** the recall reports that the bound was reached

#### Scenario: A malformed recall scope is an error
- **WHEN** the caller recalls with a URI that is not a valid context URI
- **THEN** the recall reports an invalid-URI error
- **AND** no process raises

## ADDED Requirements

### Requirement: A memory write is atomic with its embedding job
Recording a memory SHALL persist the memory's document, its assertion, and the embedding job that makes it semantically searchable as one outcome. If any part of that outcome fails, the store SHALL report the failure and SHALL leave the prior document state, assertion state, and queue state unchanged. A memory that is reported as recorded SHALL NOT be left without its embedding job queued.

#### Scenario: A successful record is searchable in principle
- **WHEN** a caller records a memory and the recording succeeds
- **THEN** the memory's document, its assertion, and its embedding job are all present
- **AND** the memory is queued for semantic indexing

#### Scenario: A failed record leaves nothing behind
- **WHEN** recording a memory fails part way through
- **THEN** the store reports the failure
- **AND** no document, assertion, or queued job from that attempt remains

#### Scenario: An enqueue failure is reported
- **WHEN** the store cannot queue the embedding job for a memory
- **THEN** recording the memory reports the failure
- **AND** the memory is not left recorded without its embedding job

### Requirement: Memory operations are classified and reportable
A failed memory operation SHALL report a reason drawn from the store's shared error classification, and SHALL NOT report a failure as an empty result. An operation that cannot be evaluated because a model or the vector index is unavailable SHALL report that the evaluation could not be performed rather than reporting that nothing was found.

#### Scenario: A store failure is not an empty recall
- **WHEN** a recall fails because the store cannot answer
- **THEN** the recall reports a classified failure
- **AND** it does not return an empty result set

#### Scenario: An unevaluable conflict read is reported as such
- **WHEN** the conflict read is issued and embeddings are unavailable
- **THEN** it reports that conflicts could not be evaluated
- **AND** it does not report that no conflicts exist
