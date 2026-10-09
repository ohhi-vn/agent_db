# Design

## Context

See `proposal.md` for motivation. What shapes the approach:

- The console markup already uses Tailwind utility classes correctly; the visual
  defect comes from `assets/tailwind.config.js` setting
  `corePlugins.preflight: false`, which removes Tailwind's base reset. Default
  browser body margin, list markers, and unstyled form controls then show
  through. The `tailwind` profile (`config/config.exs`) and the `assets.build`
  alias (`mix.exs`) already regenerate `priv/static/assets/app.css` from
  `lib/**/*.ex`; the committed file just needs to be rebuilt after the reset is
  restored.
- `AgentDbWeb.Endpoint` never serves `priv/static`: it has no `plug Plug.Static`,
  and `AgentDbWeb.Router` has no `/assets` route, so `GET /assets/app.css` and
  `GET /assets/app.js` — the exact URLs `layouts/live.ex` and `views/error_view.ex`
  emit — fall through to a 404. `mix.exs` defines only `assets.build`, so there is
  no `assets.deploy` (minify + `phx.digest`) and no `priv/static/cache_manifest.json`,
  and no config sets `cache_static_manifest`. A stylesheet rebuild cannot make an
  unreached URL served.
- The shared admin layout (`lib/agent_db_web/layouts/live.ex`) is a full
  document and never renders `@flash`. Console pages set feedback with
  `put_flash` (`document_editor_live.ex:28,88,92`), so it is dropped. The editor
  also renders failures with `inspect/1` (`:92`), which the existing
  `admin-dashboard` "Console errors rendered from the shared taxonomy"
  requirement forbids.
- `lib/agent_db_web/live/document_editor_live/edit.html.heex` is dead: the
  LiveView defines `render/1`, so the template is never used, and it references
  events (`save_draft`, `regenerate_abstract`, `regenerate_overview`,
  `delete_document`) the module does not implement.
- There is no `config/dev.exs`, `config/test.exs`, or `config/prod.exs`, and
  `config/config.exs` has no `import_config`. The test environment already opens
  no listener, but not for the reason a missing `server: false` would suggest:
  `AgentDb.Application.put_default_config/0` defaults `http_enabled` to `false`
  when `Mix.env() == :test` (`application.ex:186`), and `transport_specs/1` only
  starts the endpoint when that is true. `config/runtime.exs` sets the endpoint
  `server: true`, which `test/agent_db_web/endpoint_test.exs:186` relies on so
  that a test which turns enablement on actually binds a listener.
- `lib/agent_db_web/router.ex:73` passes `metrics: true` to `live_dashboard`.
  `Phoenix.LiveDashboard.Router.__options__/1` matches `mod when is_atom(mod)`,
  and `true` is an atom, so the value becomes the nonexistent module
  `{true, :metrics}`. The dashboard's metrics view fails. The separate
  `config :agent_db, :live_dashboard, metrics: true` entry is never read by the
  dependency and does nothing.

## Goals / Non-Goals

**Goals:**

- The console renders as its markup intends on every page (console, editor,
  error pages) with no browser-default leakage.
- The stylesheet and script a console page links are served, not 404, in every
  environment.
- Operator feedback is visible; publish failures read as a classified reason.
- Development runs with code reloading, live reload, asset watchers, and a
  rendering dashboard; test binds no listener by configuration.

**Non-Goals:**

- Adopting daisyUI or any component library (a later change).
- Changing routes, the JSON API, the trust boundary, or the store.
- Building a full `Telemetry.Metrics` catalogue; metrics may be absent.

## Decisions

### Restore Tailwind's base reset instead of adding a component library

Set `preflight: true` (remove the override), rebuild `app.css`, and commit it.
The markup is correct, so the fix belongs in the one place that removes the
reset. Alternatives: add daisyUI (new dependency, large markup rewrite, and it
does not fix the missing reset on its own); hand-write a reset (duplicates
what Tailwind ships and drifts). LiveDashboard serves its own CSS, so the reset
cannot affect it; error pages already link `app.css` and benefit directly.

### Serve the built assets, and deploy them for production

Add `plug Plug.Static, at: "/", from: :agent_db, gzip: false, only: ~w(assets
fonts images favicon.ico robots.txt)` to `AgentDbWeb.Endpoint` before the router,
so the committed `priv/static` files are reachable at the URLs the pages emit.
Add an `assets.deploy` alias to `mix.exs` (`tailwind default --minify`, `esbuild
default --minify`, `phx.digest`) and set `cache_static_manifest:
"priv/static/cache_manifest.json"` in `config/prod.exs`; route the layout's and
error view's asset URLs through `static_path/2` (or verified routes) so a
digested filename resolves in production. Alternatives: rely on a host app to
serve the assets (the standalone surface would still 404) or keep only
`assets.build` (no minified, content-addressed production bundle). The
reproducible asset command the spec names is `mix assets.build` in development
and `mix assets.deploy` in production.

### Render flash from a small shared component in the admin layout

Add a `flash_group/1` component (in `AgentDbWeb.AdminComponents`) that renders
`@flash` entries color-coded by kind, and call it inside the admin layout's
`<main>`. An alternative is Phoenix's generated `core_components.ex`, which this
project does not have; adding one file for one component is more structure than
the behavior needs. The layout already receives `@flash`, so no lifecycle
change is required.

### Classify editor failures through the existing taxonomy

Add `Context.error_message/1` delegating to `Observability.error_message/1`
(the same classifier `Context.transport_error/1` already uses) and call it from
the editor's publish failure path instead of `inspect/1`. This keeps the web
layer behind `Context` as `boundaries_test.exs` requires, and reuses the shared
taxonomy rather than inventing a second vocabulary.

### Add per-environment config; do not touch the listener gating

Add `config/dev.exs`, `config/test.exs`, `config/prod.exs` and
`import_config "#{config_env()}.exs"` at the end of `config/config.exs`.

- `dev.exs`: `debug_errors: true`, `code_reloader: true`,
  `check_origin: false`, `live_reload` patterns, and Tailwind/esbuild
  `watchers` running the same profiles `mix assets.build` uses.
- `test.exs`: `config :logger, level: :warning`.
- `prod.exs`: `debug_errors: false`.

`config/runtime.exs` is left as it is. The test environment already opens no
listener because `AgentDb.Application` defaults `http_enabled` to `false` in
test and gates the endpoint's child spec on it; setting `server: false` in
`test.exs` would instead break `endpoint_test`'s deliberate assertion that an
enabled test listener can bind. The `developer-environment` "test opens no
listener" scenario is therefore verified as existing behavior, not
re-implemented. `AGENT_DB_HTTP_PORT` and `AGENT_DB_HTTP_IP` parsing in
`runtime.exs` is unchanged.

### Fix the dashboard by disabling metrics, not by inventing them

Pass `metrics: false` to `live_dashboard` (the documented way to hide the
metrics view) and delete the unread `config :agent_db, :live_dashboard` entry.
Alternative: add an `AgentDbWeb.Telemetry` `Telemetry.Metrics` module and wire
it. That adds a new module and a metric catalogue the app does not yet commit
to; the spec only requires that metrics are real or absent. Wiring real metrics
can be a later change.

### Delete the stale editor template

Remove `lib/agent_db_web/live/document_editor_live/edit.html.heex`. The module's
`render/1` is authoritative; leaving a template that names nonexistent events is
a trap for the next edit.

## Risks / Trade-offs

- [Enabling preflight changes global base styles and could restyle LiveDashboard] →
  LiveDashboard serves its own compiled CSS under `/dev/dashboard`, not
  `app.css`, so it is unaffected; verify the dashboard renders.
- [The reset changes form control appearance beyond the console] → Only
  `priv/static/assets/app.css` is affected, and only the pages that link it; the
  JSON API serves no stylesheet.
- [Committed `app.css` can drift from markup again] → The build stays the single
  documented command (`mix assets.build`), and dev watchers now regenerate it
  automatically.
- [Making `config.exs` import per-environment files means a missing one fails the build] →
  All three are added in the same change; a missing file fails compilation loudly
  rather than falling back to a silent default.
- [Moving failure text to the taxonomy changes the editor's error wording] → The
  spec requires the classified reason and forbids `inspect/1`, so the change is
  the intended behavior; tests assert the new wording.
- [Serving `priv/static` through `Plug.Static` makes those files public, ahead of
  the browser session] → Only compiled assets live under `priv/static`; no
  content, prompts, or credentials are staged there, and the plug is scoped with
  `only:` to the asset paths. This is how a Phoenix endpoint serves assets.
- [A production deploy that forgets `mix assets.deploy` serves a stale or missing
  digest] → The manifest is written by the deploy step and named in `prod.exs`;
  the pages emit non-digested URLs, which `Plug.Static` still serves from the
  same directory.

## Migration Plan

Reverting is configuration and one rebuild: restore `preflight: false`, remove
the `import_config` line and the three environment files, revert the router's
dashboard option, remove the `Plug.Static` plug and the `assets.deploy` alias,
revert the layout's asset URLs, and re-run `mix assets.build`. No data migration;
no route or API change.

## Open Questions

- Whether to wire real `Telemetry.Metrics` for the dashboard, and whether to
  adopt daisyUI, are both deferred to separate changes; neither affects this
  change's specs, approach, or tasks.
