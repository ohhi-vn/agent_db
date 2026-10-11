# Design

## Context

See proposal.md (Why). Current state:

- `AgentDb.Application.Documents.abstract/1` falls back to `first_line(content)` (first non-empty raw line, trimmed); `overview/1` falls back to `first_chars(content)` (`String.slice(content, 0, 280)`). Both in `lib/agent_db/application/documents.ex`.
- `AgentDbWeb.Context.get_layers/1` delegates to `AgentDb.abstract/1` / `overview/1` plus `stored_layers/1` for the source badge, so a fallback fix in `Documents` propagates to the admin LLM view with no transport change.
- `AgentDb.Workers.Summarization` prompts embed raw content; stored/generated layers are returned verbatim and are not part of this fix.
- No YAML parser is currently used for document content; skill import treats `SKILL.md` as opaque text.

## Goals / Non-Goals

**Goals:**

- Frontmatter documents (notably `SKILL.md`) get a meaningful deterministic L0/L1 fallback derived from parsed identity + body.
- Plain documents without frontmatter behave byte-for-byte as today.
- Single ownership: all fallback derivation lives in `Documents`.

**Non-Goals:**

- No change to stored layers, write path, job enqueueing, embeddings, or LLM summarization prompts/content.
- No new dependency (no YAML library).
- No change to skill inventory, search ranking, or `get_layers/1` source-badge logic.
- No generic Markdown title/heading parsing beyond frontmatter `name:`/`description:` (see Decisions).

## Decisions

- **Fallback ownership stays in `AgentDb.Application.Documents`.** Add private helpers (e.g. `split_frontmatter/1`, `frontmatter_identity/1`) and route both `abstract/1` and `overview/1` fallbacks through them. Rationale: `abstract/1`, `overview/1`, and transitively `get_layers/1` share one derivation, so stored-vs-fallback sourcing cannot diverge. Alternative (fix only in `Context.get_layers/1` presentation) rejected: API/WS/MCP callers of `abstract/1` would still see `---`.
- **Strict frontmatter recognition: `---` must be the very first line, closed by a later `---`-only line.** Body is everything after the closing delimiter. Rationale: distinguishes frontmatter from a Markdown horizontal rule mid-document while covering real `SKILL.md` files. Alternatives rejected: fuzzy detection (risks misclassifying `---` separators as frontmatter) and full YAML parsing (needs a new dep).
- **Line-scan `name:`/`description:` parse, no YAML library.** Trim whitespace, accept optional single/double quotes, case-sensitive keys, first occurrence wins; multi-line or folded `description:` takes its first non-empty line. Rationale: two scalar fields do not justify a dependency or full YAML edge cases (anchors, nesting). Trade-off: exotic YAML (multiline `|` blocks beyond the first line, duplicate keys with intent) degrades to first-line value — acceptable for a fallback, and stored/LLM layers remain authoritative.
- **L0 shape: `"<name> — <description>"`, or whichever field exists alone; else first non-empty body line.** Single line, trimmed. Rationale: matches the reported expectation ("get name from skill and doc") and stays a valid abstract for LLM-view consumers. Alternative (L0 = body first line only, ignoring frontmatter fields) rejected: a skill body often starts with a generic heading, losing the skill identity the frontmatter already states.
- **L1 shape: first 280 chars of the trimmed body after frontmatter.** No identity prefix. Rationale: L0 already carries identity; L1 should preview actual content, and keeping the existing 280-char bound preserves the current contract. Alternative (prepend `name — description` to L1) rejected: duplicates L0 and shortens the body preview for no consumer benefit.
- **Unclosed/malformed frontmatter → treat whole content as body.** Rationale: fail-open preserves today's behavior instead of returning empty fallbacks for a document that merely starts with `---`.
- **Summarization prompts keep raw content (unchanged).** Rationale: the reported bug is the deterministic fallback shown before/without LLM generation; changing prompt input would alter generated-layer behavior and widen blast radius. Revisit separately if generated summaries show the same frontmatter noise.

## Risks / Trade-offs

- [Risk] A document legitimately starting with `---` as content (not frontmatter) gets misclassified → Mitigation: require a closing `---`-only line within a small header window (e.g. first 20 lines) plus at least one recognized `key: value` line; otherwise treat as body.
- [Risk] CRLF/BOM/whitespace around delimiters (`---  `, `\r\n`) → Mitigation: trim lines and strip a leading BOM before matching; cover with tests.
- [Risk] Callers snapshotting old fallback text (`---`) in tests/fixtures → Mitigation: update only frontmatter-specific assertions; plain-content fallback tests must pass unchanged.
- [Risk] Over-long `description:` makes L0 unwieldy → Mitigation: L0 is a single line; cap at a sane bound (e.g. first line, truncated to ~280 chars like L1) so the abstract stays scannable.

## Migration Plan

- Read-time-only change; no storage migration, no backfill.
- Deploy normally; rollback is a revert with no data consequences (stored layers untouched).
- Verify via `mix test` for `Documents` fallback unit tests plus admin LLM-view tests rendering a frontmatter skill.

## Open Questions

None. Out-of-scope follow-ups (Markdown `# Heading` fallback for docs without frontmatter, surfacing parsed skill name in inventory) are explicitly deferred and would need their own proposal if requested.
