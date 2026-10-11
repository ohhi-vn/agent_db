# Tasks

## 1. Reproduce the fallback fault

- [x] 1.1 Add a failing reproduction for a frontmatter `SKILL.md` (leading `---`, `name: easy-rpc`, `description:`, body) asserting `abstract/1` does not return `---` and `overview/1` excludes raw frontmatter, and verify it fails on the current `first_line`/`first_chars` fallback
- [x] 1.2 Record the owning layer and invariant (`AgentDb.Application.Documents` fallback derivation must skip frontmatter and surface `name:`/`description:` identity) and verify by tracing the failing `abstract/1`/`overview/1` read to `first_line/1`/`first_chars/1` with no behavior edit yet

## 2. Frontmatter-aware fallback in the owning layer

- [x] 2.1 Implement strict frontmatter split plus `name:`/`description:` line-scan in `AgentDb.Application.Documents` (first-line `---`, closing `---`-only line within the header window, BOM/CRLF-tolerant; unclosed or keyless blocks treated as plain body) and verify the reproduction from 1.1 now passes
- [x] 2.2 Route both L0 and L1 fallbacks through the new derivation (L0 prefers `"<name> — <description>"` or whichever field exists, else first non-empty body line; L1 is the first 280 chars of the trimmed post-frontmatter body) with stored layers still returned verbatim, and verify stored-layer precedence tests still pass
- [x] 2.3 Cover edge cases with unit tests (name-only, description-only, quoted values, unclosed delimiter, `---` mid-document, CRLF/BOM, empty body after frontmatter) and verify the new fallback test module passes

## 3. Regression and surface verification

- [x] 3.1 Run the existing fallback-adjacent suites (`mix test test/agent_db_test.exs`, summarization/layer tests, admin `document_editor_live` and `admin_live` LLM-view tests) and verify plain-document fallbacks are byte-for-byte unchanged with no new failures
- [x] 3.2 Verify the admin LLM view for a frontmatter skill via `Context.get_layers/1` (L0 shows the parsed identity with `fallback` source, L1 shows body excerpt with `fallback` source and character counts) and verify in a LiveView or `get_layers` test
