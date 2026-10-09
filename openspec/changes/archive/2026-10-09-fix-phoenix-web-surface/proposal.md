# Proposal

## Why

The console's pages are served with an incomplete stylesheet and a layout that
never renders flash, so the UI looks broken — as if a UI library were missing —
even though the class-based markup is present and correct. The visible cause is
that Tailwind's base/preflight is disabled in `assets/tailwind.config.js`, so
browser default body margins, list markers, and unstyled form controls leak
through, and the shared admin layout discards every `put_flash` result.

The endpoint also never serves the built assets: it has no `Plug.Static` plug
and no `/assets` route, so the `/assets/app.css` and `/assets/app.js` the layout
links return 404. Rebuilding the stylesheet cannot fix that on its own, and the
project never defined the production `assets.deploy` step that minifies, digests,
and writes the static manifest.

Separately, the Phoenix development environment was never wired up: there is no
`config/dev.exs`, `config/test.exs`, or `config/prod.exs`, and `config.exs`
contains no `import_config`. As a result dev runs with no code reloading, no
live reload, and no asset watchers; the test environment avoids binding a port
only because each test file manually overrides the endpoint; and the dev
LiveDashboard is passed an invalid `metrics: true`, whose value is coerced to the
nonexistent module `{true, :metrics}`.

## What Changes

- Re-enable Tailwind's base/preflight so the console's markup renders as
  intended, and rebuild and commit `priv/static/assets/app.css`.
- Serve the console's built assets from the endpoint so the linked stylesheet
  and script no longer 404, and add the missing production `assets.deploy` step
  (minify, digest, and static manifest).
- Render flash messages in the shared admin shell so operator feedback
  (publish/redirect outcomes) is visible on every console page; render the
  document editor's publish failure from the shared error taxonomy instead of
  `inspect/1`.
- Delete the stale `document_editor_live/edit.html.heex` template that references
  events the LiveView no longer implements.
- Add the missing Phoenix environment configuration — `config/dev.exs`,
  `config/test.exs`, `config/prod.exs` — and import them from `config/config.exs`;
  enable dev code reloading, live reload, and Tailwind/esbuild watchers; keep the
  test environment from opening a listener by configuration rather than by
  per-test setup.
- Fix the dev LiveDashboard so it renders: replace the invalid `metrics: true`
  with a real metrics source or an explicit disabled value, and drop the unused
  `config :agent_db, :live_dashboard` entry.
- Non-goal: no daisyUI or other component library is adopted here; that is a
  separate, later change. None of this alters routes, the JSON API, or the trust
  boundary.

## Capabilities

### New Capabilities
- `developer-environment`: the local dev/test/prod configuration and tooling that
  lets a developer run the Phoenix surface — code reloading, live reload, asset
  watchers, a test environment that binds no listener, and a working dev
  dashboard.

### Modified Capabilities
- `admin-dashboard`: the stylesheet requirement now covers the base reset that
  makes pages render with the console's intended layout, and a new requirement
  makes operator feedback (flash) visible on the pages that produce it.

## Impact

- `assets/tailwind.config.js`, `assets/css/app.css`, rebuilt
  `priv/static/assets/app.css` and `app.js`
- `lib/agent_db_web/endpoint.ex` (static asset serving), `mix.exs` (new
  `assets.deploy` alias), and `config/prod.exs` (static manifest)
- `lib/agent_db_web/layouts/live.ex`, `lib/agent_db_web/live/document_editor_live.ex`
  (and deletion of `lib/agent_db_web/live/document_editor_live/edit.html.heex`)
- `config/config.exs` plus new `config/dev.exs`, `config/test.exs`, `config/prod.exs`
- `lib/agent_db_web/router.ex` (dev dashboard) and possibly a new
  `AgentDbWeb.Telemetry` metrics module
- Console/e2e tests under `test/agent_db_web/`, and the README's console and
  assets sections
