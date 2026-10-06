# Spec Delta

## MODIFIED Requirements

### Requirement: Recalling memories
The store SHALL return stored memories on request, individually by URI, as a subtree, or filtered by type, and SHALL support restricting a recall to entries matching a term. A recall SHALL report only currently-active memories by default. When a recall returns more than one memory without a term query, the store SHALL order results by descending confidence. When a recall includes a term query, the store SHALL order the already-filtered active set by a deterministic blend of confidence and semantic similarity to the query, with exact-substring matches boosted; filtering (scope, type, active-only) SHALL precede ranking. A recall that matches nothing SHALL return an empty result rather than an error. When embeddings are unavailable or the query dim does not match stored vectors, recall SHALL fall back to confidence ordering and report backfill needed rather than failing.

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
