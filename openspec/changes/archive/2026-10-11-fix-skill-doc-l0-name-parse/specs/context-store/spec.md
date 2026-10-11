# Spec Delta

## MODIFIED Requirements

### Requirement: Caller-supplied layered content
The store SHALL store for each document a caller-supplied full content (L2) and optional caller-supplied abstract (L0) and overview (L1). Reading a document's abstract or overview SHALL return the stored L0 or L1 verbatim when present. When caller-supplied L0/L1 are absent, the store SHALL generate them automatically using a local LLM (see `llm-summarization` capability) and store the generated versions. As a final fallback, deterministic caller-independent fallbacks apply (frontmatter-aware first non-empty body line for abstract; first 280 characters of the body after frontmatter for overview). When L2 starts with a leading YAML frontmatter block (`---` line, then `name:`/`description:` fields, then closing `---` line), the L0 fallback SHALL prefer the parsed `name:`/`description:` identity (`"<name> — <description>"`, or whichever field exists) and the L1 fallback SHALL derive from the body after the closing delimiter, never from raw frontmatter. LLM generation SHALL occur asynchronously after write acknowledgement.

#### Scenario: Abstract read with caller-supplied L0
- **WHEN** a document is written with content and an explicit abstract
- **THEN** reading the abstract returns the caller-supplied text verbatim

#### Scenario: Abstract fallback when L0 absent
- **WHEN** a document is written with content and no abstract
- **THEN** reading the abstract returns the first non-empty line of the stored content

#### Scenario: Abstract fallback to LLM-generated when L0 absent
- **WHEN** a document is written with content and no abstract
- **THEN** reading the abstract returns the LLM-generated abstract once available
- **AND** before LLM generation completes, returns the first non-empty line of stored content

#### Scenario: Overview fallback to LLM-generated when L1 absent
- **WHEN** a document is written with content and no overview
- **THEN** reading the overview returns the LLM-generated overview once available
- **AND** before LLM generation completes, returns the first 280 characters of content

#### Scenario: Skill L0 fallback uses frontmatter identity, not the delimiter
- **WHEN** a `SKILL.md` is written with leading frontmatter carrying `name: easy-rpc` and a `description:` and no stored abstract
- **THEN** reading the abstract does not return `---`
- **AND** it returns the parsed identity combining `name` and `description` on one line

#### Scenario: Skill L1 fallback skips raw frontmatter
- **WHEN** the same frontmatter skill has no stored overview
- **THEN** reading the overview returns the first 280 characters of the body after the closing `---` delimiter
- **AND** it does not contain the raw `name:` or `description:` frontmatter lines

#### Scenario: Plain document without frontmatter is unchanged
- **WHEN** a document without leading `---` frontmatter is written with no stored layers
- **THEN** reading the abstract returns the first non-empty line of content
- **AND** reading the overview returns the first 280 characters of content

#### Scenario: Unclosed frontmatter is treated as plain content
- **WHEN** a document starts with `---` but has no closing `---` delimiter
- **THEN** fallback derivation treats the whole content as body (existing first-line / first-280-chars behavior)
