# Spec Delta

## MODIFIED Requirements

### Requirement: Vector similarity search
The store SHALL provide a vector search operation that accepts a query text, generates its embedding, and returns the top-k most similar documents by cosine similarity. Results SHALL include the document URI, content, abstract, overview, and similarity score. A search issued while the embedding model is still loading SHALL report that the model is loading, and SHALL NOT be reported as though the query itself were invalid or the capability permanently unavailable. A search whose query embedding dimensionality does not match the active vector table SHALL return `{:error, :dim_mismatch}` and SHALL NOT return cross-dim rankings.

**That field set is the default: when a caller selects fields with `:fields`, the result carries only the selected fields and the default above applies only when `:fields` is omitted.**

#### Scenario: Vector search returns ranked results
- **WHEN** documents exist with embeddings and the caller searches "machine learning" with `mode: :vector`
- **THEN** results are ordered by cosine similarity descending
- **AND** each result includes a similarity score between -1 and 1
- **AND** the top result is semantically related to the query

#### Scenario: Vector search respects top-k limit
- **WHEN** caller requests `top_k: 3`
- **THEN** at most 3 results are returned

#### Scenario: Vector search scoped to subtree
- **WHEN** documents exist under `viking://resources/p/` and `viking://resources/q/` and caller searches with `scope: "viking://resources/p"` and `mode: :vector`
- **THEN** only results under the `viking://resources/p/` prefix are returned

#### Scenario: Searching while the model loads is reported as loading
- **WHEN** a vector search is issued and the embedding model is still loading
- **THEN** the search reports that the model is loading
- **AND** the same search succeeds once the model is loaded

#### Scenario: Cross-dim query is refused, not misranked
- **WHEN** the query embeds to a dim different from the active vector table
- **THEN** the search returns `{:error, :dim_mismatch}`
- **AND** no results scored across dims are returned

#### Scenario: Selected fields replace the default field set
- **WHEN** a caller searches with `mode: :vector` and `fields: [:uri, :abstract, :score]`
- **THEN** each result carries only the selected fields
- **AND** ranking and ordering are unchanged from an unselected search
