defmodule AgentDbWeb.Layouts do
  use AgentDbWeb, :html_helpers
  import Phoenix.Controller, only: [get_csrf_token: 0]

  def live(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="csrf-token" content={get_csrf_token()}/>
        <title>AgentDb Admin</title>
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
        <script defer phx-track-static type="text/javascript" src="/assets/app.js"></script>
      </head>
      <body class="bg-gray-50">
        <%= @inner_content %>
      </body>
    </html>
    """
  end
end
