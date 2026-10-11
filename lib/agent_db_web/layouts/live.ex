defmodule AgentDbWeb.Layouts do
  @moduledoc false
  use AgentDbWeb, :html_helpers
  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias AgentDbWeb.AdminComponents

  def live(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="csrf-token" content={get_csrf_token()}/>
        <title>AgentDb Admin</title>
        <link phx-track-static rel="stylesheet" href={AgentDbWeb.Endpoint.static_path("/assets/app.css")} />
        <script defer phx-track-static type="text/javascript" src={AgentDbWeb.Endpoint.static_path("/assets/app.js")}></script>
      </head>
      <body class="bg-gray-50">
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  # The console shell: a persistent header bar plus a hideable sidebar beside
  # the page. It is the whole document, as `live/1` is, so every console page
  # shares one navigation and the active entry follows the page's `@active`.
  # The header title is derived from `@active` so no page needs a new assign.
  def admin(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="csrf-token" content={get_csrf_token()}/>
        <title>AgentDb Admin — <%= admin_title(@active) %></title>
        <link phx-track-static rel="stylesheet" href={AgentDbWeb.Endpoint.static_path("/assets/app.css")} />
        <script defer phx-track-static type="text/javascript" src={AgentDbWeb.Endpoint.static_path("/assets/app.js")}></script>
      </head>
      <body class="bg-gray-50">
        <div id="admin-shell" data-sidebar="shown" class="flex min-h-screen flex-col">
          <header class="admin-header flex items-center gap-3 bg-gradient-to-r from-indigo-700 via-blue-700 to-sky-600 px-4 py-3 text-white shadow">
            <button
              id="sidebar-toggle"
              type="button"
              aria-controls="admin-sidebar"
              aria-expanded="true"
              aria-label="Toggle navigation sidebar"
              class="rounded p-2 text-white hover:bg-white/15 focus:outline-none focus:ring-2 focus:ring-white/70"
            >
              <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden="true">
                <path d="M3 5h14M3 10h14M3 15h14" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
              </svg>
            </button>
            <div class="flex items-baseline gap-2">
              <span class="text-lg font-semibold tracking-tight">AgentDb</span>
              <span class="text-sm text-blue-100">Admin Console</span>
            </div>
            <span class="mx-2 hidden text-white/40 sm:inline">/</span>
            <h1 class="text-sm font-medium text-white"><%= admin_title(@active) %></h1>
          </header>
          <div class="flex min-h-0 flex-1">
            <aside id="admin-sidebar" class="admin-sidebar w-56 shrink-0 border-r border-gray-200 bg-white">
              <div class="border-b border-gray-100 px-4 py-3 text-xs font-semibold uppercase tracking-wider text-gray-500">
                Console
              </div>
              <div class="py-2">
                <AdminComponents.sidebar active={@active} />
              </div>
            </aside>
            <main class="admin-content min-w-0 flex-1">
              <AdminComponents.flash_group flash={@flash} />
              <div class="space-y-6 p-6">
                <%= @inner_content %>
              </div>
            </main>
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp admin_title(:overview), do: "Overview"
  defp admin_title(:documents), do: "Documents"
  defp admin_title(:storage), do: "Storage"
  defp admin_title(:skills), do: "Skills"
  defp admin_title(:sessions), do: "Sessions"
  defp admin_title(_), do: "Overview"
end
