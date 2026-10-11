# Proposal

## Why

The `/admin` console is functional but visually flat: gray cards on gray background with no header bar and a fixed always-visible sidebar. Operators cannot maximize content width for wide tables (documents, skills, queue) and have no at-a-glance identity or context in the shell.

## What Changes

- Add a persistent header bar to the admin shell shared by all `/admin/*` pages (and the document editor): product identity, current page title, and a sidebar toggle control.
- Make the sidebar collapsible/hidden: operator can hide it for a full-width content view and restore it; the choice persists for the session and works on all console pages without a full reload.
- Refresh the console visual theme for a cleaner, more colorful look while keeping the existing layout structure: colored section accents, clearer card headers, improved spacing/typography, and consistent status colors — no information removed.
- Keep all existing console behavior unchanged: same five pages, same navigation targets, same realtime updates, same trust boundary (`/admin` browser pipeline + operator facade only).

## Capabilities

### New Capabilities

- None — this change restyles and extends the existing console shell; no new behavior domain.

### Modified Capabilities

- `admin-dashboard`: console shell gains a header bar and a hideable sidebar (navigation requirement), and the rendered stylesheet/visual theme changes (stylesheet requirement). All data, realtime, and trust-boundary requirements stay as-is.

## Impact

- `lib/agent_db_web/layouts/live.ex` — admin shell: header bar, collapsible sidebar container, content width handling.
- `lib/agent_db_web/live/admin_components.ex` — sidebar nav, flash group, section card presentation (colors, headers).
- `assets/css/app.css` + generated `priv/static/assets/app.css` — theme colors, header/sidebar styles, rebuilt via documented asset build.
- Tests: navigation/component/stylesheet LiveView tests; no store, API, or auth changes.
