## Purpose

Lets an agent record durable, typed facts about its user and its work, and read them back with their provenance intact, so that a revised belief supersedes its predecessor instead of silently overwriting or accumulating alongside it.

## Requirements

### Requirement: Typed durable memory
The store SHALL allow a caller to record a durable fact as a memory at a caller-chosen URI beneath a memories root, and SHALL associate each memory with exactly one type drawn from a fixed taxonomy of `profile`, `preferences`, `entities`, `events`, and `experiences`. A memory SHALL be readable as an ordinary document of the context tree. Recording a memory SHALL NOT require a language model to be loaded.

#### Scenario: A recorded memory reports its type
- **WHEN** a caller records a memory of type `preferences` at `viking://user/memories/preferences/language`
- **THEN** reading that memory back reports its type as `preferences`
- **AND** reading its content returns the value the caller supplied

#### Scenario: An unrecognized type is rejected
- **WHEN** a caller attempts to record a memory with a type outside the taxonomy
- **THEN** the store reports an error naming the invalid type
- **AND** no memory is recorded at that URI

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

### Requirement: Conflict resolution by supersession
When a memory at a URI is revised, the store SHALL retain the prior assertion, mark it superseded rather than deleting it, and associate it with the assertion that replaced it. A URI SHALL have at most one active assertion. The store SHALL expose a superseded assertion's history for inspection, including the value previously held and the assertion that superseded it.

#### Scenario: A revised belief supersedes its predecessor
- **WHEN** memory `user uses Go` is active at `viking://user/memories/preferences/language`
- **AND** the caller records `user moved the project to Elixir` at that same URI
- **THEN** `user uses Go` is retained with a superseded status
- **AND** it is associated with the assertion that replaced it
- **AND** `user moved the project to Elixir` is the active assertion at that URI

#### Scenario: Exactly one assertion is active per URI
- **WHEN** a memory at a URI has been revised more than once
- **THEN** exactly one of its assertions is active
- **AND** every superseded assertion names its successor

#### Scenario: Superseded history is inspectable
- **WHEN** a memory at a URI has been revised
- **THEN** the store reports the prior value and the assertion that superseded it

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

### Requirement: Forgetting a memory
The store SHALL allow a caller to remove a memory. Forgetting a memory SHALL remove both its value and its provenance, such that a subsequent recall does not return it and its content is no longer readable at that URI. Forgetting a memory SHALL leave other memories unaffected. Forgetting a URI that holds no memory SHALL report that no memory was found.

#### Scenario: A forgotten memory is no longer recalled
- **WHEN** a caller forgets a recorded memory
- **THEN** recalling that memory's type does not return it
- **AND** reading its URI reports it as not found

#### Scenario: Forgetting removes provenance, not just the value
- **WHEN** a caller forgets a memory
- **THEN** the store reports no confidence, source, or superseded history for that URI

#### Scenario: Forgetting one memory leaves others intact
- **WHEN** two memories exist and the caller forgets one of them
- **THEN** the other remains retrievable with its provenance

#### Scenario: Forgetting a URI with no memory
- **WHEN** the caller forgets a URI that holds no memory
- **THEN** the store reports that no memory was found

### Requirement: Memories are ordinary tree documents
A memory SHALL be stored as a document of the context tree and SHALL be reachable through the store's ordinary navigation and retrieval operations without a memory-specific path. A memory SHALL be discoverable by a term search scoped to the memories root. Recording a memory SHALL enqueue embedding generation so that the memory is retrievable by semantic search once inference is available, and SHALL NOT enqueue abstract or overview summarization.

#### Scenario: A memory appears in tree navigation
- **WHEN** a memory is recorded beneath the memories root
- **THEN** listing the memories root reports the memory
- **AND** the memory is reachable by reading its URI

#### Scenario: A memory is term-searchable
- **WHEN** a memory whose content contains a distinctive term is recorded
- **AND** a term search is scoped to the memories root
- **THEN** the memory is returned by that search

#### Scenario: Recording does not require summarization
- **WHEN** a memory is recorded while no language model is loaded
- **THEN** the memory is recorded successfully
- **AND** no summarization work is enqueued for it
