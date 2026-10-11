# Proposal

## Why

Skill and document L0/L1 fallbacks derive from raw L2 text, so a `SKILL.md` starting with YAML frontmatter reports `---` (3 chars) as its L0 abstract and raw `name:`/`description:` frontmatter as its L1 overview. Operators see a meaningless abstract in the admin LLM view and search/recall consumers receive frontmatter noise instead of the skill identity.

## What Changes

- Make the deterministic L0/L1 fallback frontmatter-aware: strip a leading `--- ... ---` YAML block before deriving fallbacks.
- Parse `name:` and `description:` from the stripped frontmatter for skill/doc identity:
  - L0 fallback for a document with `name:`/`description:` returns `"<name> — <description>"` (or whichever field exists, truncated to one line); otherwise falls back to the first non-empty body line.
  - L1 fallback returns the first 280 chars of the body after frontmatter (not raw frontmatter).
- Apply the same derivation to every L0/L1 fallback reader (`abstract/1`, `overview/1`, and the admin `get_layers/1` view which delegates to them) so stored-vs-fallback sourcing stays consistent.
- Keep stored (caller-supplied or LLM-generated) layers verbatim; only the no-stored-layer fallback path changes.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `context-store`: deterministic L0/L1 fallback derivation becomes frontmatter-aware with `name:`/`description:` parsing for skill/doc identity.

## Impact

- Affected code: `AgentDb.Application.Documents` (`abstract/1`, `overview/1`, `first_line/1`, `first_chars/1`), `AgentDbWeb.Context.get_layers/1` presentation (inherits new text, no logic change expected), LLM summarization prompts (only if design chooses to feed stripped body — decided in design).
- Existing callers of `abstract/1` / `overview/1` without stored layers will see changed fallback text for frontmatter documents; plain documents without frontmatter are unchanged.
- No storage migration: stored layers untouched; fallback is computed at read time.
