# Spec Delta

## Purpose

Lets an agent use the store as its durable memory: recall what it has learned
within a bound, scoped to the provenance it cares about, and drive the
candidate lifecycle itself when the store asks it to confirm a belief.

## ADDED Requirements

### Requirement: Recall is bounded
A recall SHALL accept a `:top_k` bound and SHALL apply it in storage, so a caller receives at most that many memories and the store does not materialize more than it must to satisfy the bound. A recall SHALL report whether its result was truncated by the bound, so a caller can distinguish "there is nothing more" from "there is more than I asked for". A `:top_k` outside the accepted range SHALL report an error rather than silently falling back to a default.

#### Scenario: A bounded recall returns at most the bound
- **WHEN** a caller recalls with `top_k: 5` and many memories match
- **THEN** at most 5 memories are returned
- **AND** the recall reports that the bound was reached

#### Scenario: An unbounded recall still reports truncation
- **WHEN** a caller recalls without a `:top_k` and the matched set exceeds the default bound
- **THEN** the recall reports that the result was truncated

#### Scenario: An out-of-range bound is refused
- **WHEN** a caller recalls with `top_k: 0` or a value above the accepted maximum
- **THEN** the recall reports an invalid-limit error
- **AND** no memories are returned under a substituted bound

### Requirement: Recall is scoped by provenance
A recall SHALL accept a `:source` filter, so a caller can restrict the result to memories recorded from that source. A recall issued with a `:source` filter SHALL return only memories whose recorded source matches it.

#### Scenario: A recall can be scoped by source
- **WHEN** memories were recorded from sources `session-a` and `session-b`
- **AND** the caller recalls with `source: "session-a"`
- **THEN** only memories recorded from `session-a` are returned

#### Scenario: A source filter that matches nothing returns an empty result
- **WHEN** the caller recalls with a source no memory was recorded from
- **THEN** an empty result is returned
- **AND** no error is reported

### Requirement: Importance participates in ranking
The importance a caller assigns to a memory SHALL affect the order in which memories are recalled. Two memories of equal confidence SHALL be ordered by descending importance. A caller that assigns no importance SHALL have the documented default recorded, and that default SHALL be applied to ranking in the same way as any other value.

#### Scenario: Importance orders equally-confident memories
- **WHEN** two memories have equal confidence and different importance
- **THEN** the more important memory is recalled first

#### Scenario: The default importance participates in ranking
- **WHEN** two memories have equal confidence and were both recorded without an explicit importance
- **THEN** they are ordered consistently with the documented default importance

### Requirement: An agent can drive the candidate lifecycle
The store SHALL expose, to an agent over its remote tool surface, the operations needed to complete a candidate's lifecycle: listing the candidates waiting for review, promoting a candidate, and rejecting a candidate. A promoted candidate SHALL become the active assertion at its URI and SHALL be returned by default recall. A rejected candidate SHALL leave no value, provenance, or history at its URI. The remote tool surface SHALL accept the same option names as the underlying operations.

#### Scenario: An agent lists pending candidates
- **WHEN** an agent asks for the memories waiting for review
- **THEN** the store reports them with their URI, value, and status

#### Scenario: An agent promotes a candidate
- **WHEN** an agent promotes a waiting candidate
- **THEN** that memory becomes the active assertion at its URI
- **AND** default recall returns it

#### Scenario: An agent rejects a candidate
- **WHEN** an agent rejects a waiting candidate
- **THEN** no value, provenance, or history remains at that URI

### Requirement: Memory statistics are reportable
The store SHALL report statistics describing what it holds: the number of memories per type, the number of memories by status, the number waiting for review, and the number of memories that have never been surfaced. These statistics SHALL be answerable without loading every memory.

#### Scenario: Counts per type are reported
- **WHEN** memories of several types exist
- **THEN** the store reports how many memories of each type it holds

#### Scenario: The review backlog is reported
- **WHEN** candidates are waiting for review
- **THEN** the store reports how many are waiting

#### Scenario: Statistics do not require loading every memory
- **WHEN** statistics are requested over a store holding many memories
- **THEN** the counts are computed by the store
- **AND** the full memory set is not materialized to answer the call

### Requirement: Memory recall reuses stored embeddings
A term recall SHALL reuse the embedding vectors already stored with the memories it ranks, and SHALL NOT run a fresh inference over every candidate value on the read path. When the stored vectors cannot answer the query — because they are absent, or because their dimension does not match the query's — the recall SHALL fall back to confidence ordering, SHALL report that semantic ranking was not applied, and SHALL NOT fail.

#### Scenario: A term recall does not embed every candidate
- **WHEN** a term recall runs over memories whose embeddings are stored
- **THEN** the recall ranks those memories using the stored vectors
- **AND** no inference call is made for the candidate values

#### Scenario: Absent embeddings fall back and say so
- **WHEN** a term recall runs and no stored embeddings are available for the candidates
- **THEN** the results are confidence-ordered
- **AND** the recall reports that semantic ranking was not applied

#### Scenario: A dimension mismatch falls back and says so
- **WHEN** a term recall runs and the stored vectors' dimension differs from the query's
- **THEN** the results are confidence-ordered
- **AND** the recall reports that semantic ranking was not applied
- **AND** the recall does not fail
