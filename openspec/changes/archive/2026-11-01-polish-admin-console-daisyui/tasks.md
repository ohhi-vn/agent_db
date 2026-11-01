# Tasks

## 1. Page-level notice and heading migration

- [x] 1.1 Migrate notices in `overview_live.ex`, `storage_live.ex`, `sessions_live.ex` from `rounded bg-blue-50 ... text-blue-900` to `alert alert-info` and headings to `text-base-content`; verify `mix test` admin suites pass.
- [x] 1.2 Migrate notices in `documents_live.ex`, `skills_live.ex`, `memories_live.ex` the same way; verify `mix test` admin suites pass.
- [x] 1.3 Replace raw gray heading/count text in the six pages with `text-base-content`/`text-base-content/70`; verify pages render and tests pass.

## 2. Document editor migration

- [x] 2.1 Migrate `document_editor_live.ex` notice to `alert alert-info`/`alert alert-error` and textarea to `textarea textarea-bordered`; verify editor renders and edit/save test passes.
- [x] 2.2 Migrate publish button to `btn btn-primary btn-sm` and status text colors (`text-warning` unsaved, `text-base-content/60` saved); verify document editor live test passes.

## 3. Remaining component migration

- [x] 3.1 Migrate skill-file chips in `admin_components.ex` (`rounded bg-gray-50 ... text-gray-700`) to `badge badge-ghost` or `bg-base-200 text-base-content`; verify import flow tests pass.
- [x] 3.2 Migrate LLM layer excerpt containers (`bg-gray-50 ... text-gray-900`) to `bg-base-200 text-base-content`; verify llm layer component tests pass.
- [x] 3.3 Colorize status text: enabled/disabled, health ok/down, queue availability using status color utilities (see design D3); verify admin console tests pass.

## 4. Shell token cleanup

- [x] 4.1 Replace `bg-gray-50` body and `text-white`/`text-blue-100` header text in `layouts/live.ex` with `bg-base-200` and `text-primary-content`/`text-primary-content/70`; verify navigation tests pass.
- [x] 4.2 Replace `border-gray-100` sidebar divider and `text-gray-500` "Console" label with base tokens; verify sidebar renders and tests pass.
- [x] 4.3 Remove any CSS rules left unused by the completed migration from `assets/css/app.css`; verify `mix assets.build` succeeds and no removed selectors remain.

## 5. Verification

- [x] 5.1 Run `mix assets.deploy` and regenerate `priv/static/assets/app.css`; verify digest builds without 404s on local boot.
- [x] 5.2 Run `mix test` for `admin_components_test`, `admin_console_test`, `admin_live_test`, `admin_navigation_test`, `admin_stylesheet_test`, and `document_editor_live_test`; verify all pass.
- [x] 5.3 Run `mix lint:quick`; verify no failures.

## Workflow follow-up

- Archive the change after review requirements are satisfied.
- Verify the archived result.