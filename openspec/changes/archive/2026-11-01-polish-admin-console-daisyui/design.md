# Design

## Context

The console shell and shared primitives were migrated to daisyUI in
`redesign-admin-console-daisyui`; the remaining work is the incomplete
page-level and component-level migration plus token cleanup. See `proposal.md`.

Current state (from code inspection):

- `layouts/live.ex` shell uses `bg-primary`/`base-*` tokens in a few places but
  still `bg-gray-50` body, `text-white`/`text-blue-100` header text, and
  `border-gray-100` sidebar divider.
- Page modules (`overview`, `documents`, `storage`, `skills`, `sessions`,
  `memories`) render notices as `rounded bg-blue-50 ... text-blue-900` and
  headings as `text-gray-900`.
- `document_editor_live.ex` is entirely unmigrated: textarea, button, notice,
  and unsaved/saved status text use bespoke classes.
- `admin_components.ex` chips use `rounded bg-gray-50 ... text-gray-700` and
  LLM layer excerpts use `bg-gray-50 ... text-gray-900`; status text
  (enabled/disabled, health, queue) is uncolored.

## Goals / Non-Goals

**Goals:**
- Complete the daisyUI migration so every console surface uses daisyUI
  component classes and themed tokens.
- Make status values visually distinct using daisyUI color utilities.
- Keep the editor's domain-specific panes and document tree CSS.
- Regenerate committed CSS and keep tests green.

**Non-Goals:**
- No dark-mode toggle (deferred; light theme only).
- No new pages, routes, events, or store behavior.
- No change to component structure or data loading.

## Decisions

### D1: Finish migration page-by-page, component-last

Migrate page notices/headers first (mechanical), then the document editor, then
the remaining chips/excerpts in `admin_components.ex`, then token cleanup in the
shell. This keeps each diff reviewable and lets tests run between steps.

### D2: Use daisyUI semantic tokens for all text/surface colors

Replace `text-gray-*`, `bg-gray-*`, `border-gray-*`, `text-blue-*`,
`bg-blue-*` with `text-base-content`, `bg-base-100/200/300`,
`border-base-200/300`, `text-primary`, `bg-primary`, and status utilities
(`text-success`, `text-warning`, `text-error`, `text-info`). Rationale: the
current mixed palette defeats theming; tokens make the light theme coherent and
keep a future dark theme working without further edits.

### D3: Status color mapping

- enabled → `text-success` (or `badge-success`)
- disabled → `text-base-content/60` (neutral, de-emphasized)
- health ok → `text-success`; down → `text-error`
- queue unavailable → `text-error`
- unsaved changes → `text-warning`
- saved → `text-base-content/60`

Where a status is already a daisyUI badge (layer source), keep badges.

### D4: Notices become `alert`

Replace `rounded bg-blue-50 px-3 py-2 text-sm text-blue-900` with
`alert alert-info` (success notices use `alert alert-success`, errors use
`alert alert-error`). The `flash_group` already uses `alert`; page-level
notices should match.

### D5: Document editor textarea and button

Textarea: `textarea textarea-bordered w-full font-mono text-sm` (rows retained).
Button: `btn btn-primary btn-sm`. Notice: `alert alert-info`/`alert-error`
based on outcome (success/info → info). Status text uses D3 colors.

### D6: Retain custom CSS

Keep `.document-tree`, `.editor-pane`, `.phx-*`, sidebar show/hide rule, and
`.admin-header`/`.admin-sidebar`/`.admin-content` hooks (tests and layout
reference them). Remove only rules whose selectors no longer appear.

### D7: No test behavior changes

Presentation tests may need class-string updates where they assert on removed
classes; behavioral assertions stay. The stylesheet test continues to assert
reset + key classes.

## Risks / Trade-offs

- [Token replacement touches many lines] → Mechanical; run `mix format` and the
  admin test suite after each page group.
- [Some gray utilities are intentional (monospace chips)] → Keep `font-mono`
  and spacing utilities; only swap color utilities.
- [Generated CSS size] → daisyUI already included; no new growth expected.
- [Dark mode still not delivered] → Tokens keep it possible later; out of scope.

## Migration Plan

1. Migrate page-level notices and headings (6 pages).
2. Migrate `document_editor_live.ex`.
3. Migrate remaining chips/excerpts in `admin_components.ex`.
4. Token cleanup in `layouts/live.ex` shell.
5. Status colorization.
6. Remove unused CSS; run `mix assets.build`.
7. Update presentation tests if needed; run `mix test` for admin suites and
   `mix lint:quick`.

Rollback: revert the change commit; regenerate assets. No data migration.