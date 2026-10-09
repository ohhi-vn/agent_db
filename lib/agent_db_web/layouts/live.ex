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

  # The console shell: a persistent sidebar beside the page. It is the whole
  # document, as `live/1` is, so every console page shares one navigation and the
  # active entry follows the page's `@active`.
  def admin(assigns) do
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
        <div class="flex min-h-screen">
          <aside class="admin-sidebar w-56 shrink-0 border-r border-gray-200 bg-white">
            <div class="px-4 py-4 text-lg font-semibold text-gray-900">AgentDb</div>
            <AdminComponents.sidebar active={@active} />
          </aside>
          <main class="admin-content min-w-0 flex-1">
            <AdminComponents.flash_group flash={@flash} />
            <%= @inner_content %>
          </main>
        </div>
      </body>
    </html>
    """
  end
end
