# Spec Delta

## ADDED Requirements

### Requirement: Search results are selectable by field
`search/2` SHALL accept a `:fields` option naming which per-result fields to return, drawn from `:uri`, `:abstract`, `:overview`, `:content`, and `:score`, applying uniformly to keyword, vector, and hybrid modes. Omitting `:fields` SHALL return today's full result set unchanged. An unrecognized field name SHALL return `{:error, {:invalid_fields, value}}` rather than being ignored or substituted.

#### Scenario: Search returns abstracts and scores only
- **WHEN** a caller searches with `fields: [:uri, :abstract, :score]`
- **THEN** each result carries only those three fields
- **AND** no result carries its document content

#### Scenario: Omitting fields returns today's result set
- **WHEN** a caller searches without a `:fields` option
- **THEN** each result carries the same fields it carried before this option existed
- **AND** an existing caller is unaffected

#### Scenario: Unrecognized field is refused
- **WHEN** a caller searches with `fields: [:uri, :checksum]`
- **THEN** the search returns `{:error, {:invalid_fields, [:uri, :checksum]}}`
- **AND** no results are returned under a substituted field set

#### Scenario: Field selection applies to every mode
- **WHEN** the same `:fields` selection is used with `mode: :keyword`, `mode: :vector`, and `mode: :hybrid`
- **THEN** each mode's results carry the same selected fields
- **AND** hybrid fusion and ranking are unaffected by the selection

#### Scenario: Selection does not pay for unselected content
- **WHEN** a caller searches with `fields: [:uri, :abstract]` over a store whose documents are large
- **THEN** the returned results carry no document content
- **AND** the operation does not materialize document content the caller cannot receive

### Requirement: Fallback abstract carries no markup marker
The deterministic abstract fallback SHALL NOT return a leading markdown heading marker, blockquote marker, or list bullet as part of its text. A first line that opens with such a marker SHALL have the marker removed, so the fallback is the line's text rather than its formatting.

#### Scenario: Heading marker is stripped from the abstract fallback
- **WHEN** a document is written with no stored or generated abstract and its first non-empty line is `## Storage layout`
- **THEN** `abstract/1` returns `Storage layout`
- **AND** the returned text carries no leading `#` characters

#### Scenario: Plain first line is returned unchanged
- **WHEN** a document's first non-empty line carries no leading marker
- **THEN** the fallback returns that line as it is

### Requirement: Fallback overview truncates on a word boundary
The deterministic overview fallback SHALL truncate at the end of a word rather than at a fixed character count, so the fallback never ends mid-word or mid-sentence. A document whose body is shorter than the bound SHALL be returned whole, and a fallback trimmed by the bound SHALL end at a word boundary preceded by complete words only.

#### Scenario: Long body truncates at a word boundary
- **WHEN** a document is written with no stored or generated overview and its body exceeds the overview bound
- **THEN** `overview/1` returns a prefix ending at a word boundary
- **AND** the returned text does not end in a partial word

#### Scenario: Short body is returned whole
- **WHEN** a document's body is shorter than the overview bound
- **THEN** the fallback returns the whole body without trimming
