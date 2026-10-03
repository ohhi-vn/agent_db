defmodule AgentDbWeb.ErrorView do
  @moduledoc false
  use AgentDbWeb, :view

  def render("404.json", _assigns) do
    %{error: "not_found"}
  end

  def render("500.json", _assigns) do
    %{error: "internal_server_error"}
  end

  def render("404.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <title>404 Not Found</title>
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
      </head>
      <body class="bg-gray-50 min-h-screen flex items-center justify-center">
        <div class="text-center">
          <h1 class="text-6xl font-bold text-gray-900">404</h1>
          <p class="text-xl text-gray-600 mt-4">Page not found</p>
          <a href="/admin" class="mt-6 inline-block text-blue-600 hover:text-blue-800">Go to Admin</a>
        </div>
      </body>
    </html>
    """
  end

  def render("500.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <title>500 Internal Server Error</title>
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
      </head>
      <body class="bg-gray-50 min-h-screen flex items-center justify-center">
        <div class="text-center">
          <h1 class="text-6xl font-bold text-gray-900">500</h1>
          <p class="text-xl text-gray-600 mt-4">Internal server error</p>
          <a href="/admin" class="mt-6 inline-block text-blue-600 hover:text-blue-800">Go to Admin</a>
        </div>
      </body>
    </html>
    """
  end
end
