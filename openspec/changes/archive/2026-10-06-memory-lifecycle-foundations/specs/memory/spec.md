# Spec Delta

## MODIFIED Requirements

### Requirement: Recording and revising a memory
The store SHALL record a memory's value, and SHALL treat the URI as the identity of the thing being asserted. Recording a memory at a URI that already holds a memory SHALL revise that URI's memory in place rather than produce a second one. Recording at a URI that holds no memory SHALL create it. The store SHALL NOT reject a revision on the grounds that a memory already exists there. A caller MAY record a memory as a candidate; a candidate SHALL be stored but SHALL be excluded from default recall until explicitly promoted, and promoting a candidate SHALL make it the active assertion at its URI. Rejecting a candidate SHALL remove it without a trace.

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

#### Scenario: Candidate is hidden until promoted
- **WHEN** a caller records a memory as a candidate
- **THEN** default recall does not return it
- **AND** promoting it makes it the active assertion at its URI

#### Scenario: Rejected candidate leaves no trace
- **WHEN** a caller rejects a candidate memory
- **THEN** no value, provenance, or history remains at that URI

### Requirement: Recalling memories
The store SHALL return stored memories on request, individually by URI, as a subtree, or filtered by type, and SHALL support restricting a recall to entries matching a term. A recall SHALL report only currently-active memories by default. When a recall returns more than one memory without a term query, the store SHALL order results by descending confidence. When a recall includes a term query, the store SHALL order the already-filtered active set by a deterministic blend of confidence and semantic similarity to the query, with exact-substring matches boosted and stale, rarely-surfaced memories penalized; filtering (scope, type, active-only) SHALL precede ranking. Recalling a memory SHALL record that it was surfaced. A recall that matches nothing SHALL return an empty result rather than an error. When embeddings are unavailable or the query dim does not match stored vectors, recall SHALL fall back to confidence ordering and report backfill needed rather than failing.

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

### Requirement: Provenance of an assertion
The store SHALL record, for every assertion of a memory, the confidence with which it is held, the importance assigned to it, and the source it came from, and SHALL permit a caller to supply confidence, importance, and source. A caller that supplies no confidence SHALL have a documented default recorded, and a caller that supplies no importance SHALL have a documented default recorded. The store SHALL expose the recorded confidence, importance, source, and last-surfaced time when a memory is recalled.

#### Scenario: Caller-supplied provenance is retained
- **WHEN** a caller records a memory with confidence `0.9` and a source identifying the originating session
- **THEN** recalling that memory reports confidence `0.9` and that source

#### Scenario: Confidence defaults when omitted
- **WHEN** a caller records a memory without a confidence
- **THEN** the memory is recorded with a default confidence
- **AND** recalling it reports that default

#### Scenario: Importance defaults when omitted
- **WHEN** a caller records a memory without an importance
- **THEN** the memory is recorded with a default importance
- **AND** recalling it reports that default

## ADDED Requirements

### Requirement: Cross-URI conflict surfacing
The store SHALL provide a read that reports pairs of active memories at distinct URIs whose values are semantically similar enough to be possible conflicts. The read SHALL NOT resolve, merge, or modify any memory. Detection SHALL reuse already-stored embedding vectors and SHALL NOT run new inference. When embeddings are unavailable, the read SHALL report that conflicts cannot be evaluated rather than returning an empty verdict.

#### Scenario: Similar values at distinct URIs are reported
- **WHEN** two active memories at distinct URIs hold highly similar values
- **THEN** the conflict read reports the pair

#### Scenario: Surfacing never modifies memories
- **WHEN** the conflict read reports a pair
- **THEN** both memories remain active and unchanged

#### Scenario: Unavailable embeddings are reported, not silent
- **WHEN** the conflict read is issued while embeddings are unavailable
- **THEN** it reports that conflicts cannot be evaluated
