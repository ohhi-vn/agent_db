defmodule AgentDbWeb.AdminNavigationTest do
  @moduledoc """
  The console as one navigable surface.

  Every page is its own LiveView, but they share one sidebar: each page carries
  the same links, marks itself as the current page, and the links are live
  navigation (handled inside the console's `live_session`) rather than plain
  anchors. The document editor keeps the sidebar too, with Documents current.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AgentDb.Cache

  @endpoint AgentDbWeb.Endpoint

  @pages [
    {"/admin", "Overview"},
    {"/admin/documents", "Documents"},
    {"/admin/storage", "Storage"},
    {"/admin/skills", "Skills"},
    {"/admin/sessions", "Sessions"}
  ]

  @nav Enum.map(@pages, fn {path, _heading} -> path end)

  setup do
    endpoint = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

    Application.put_env(
      :agent_db,
      AgentDbWeb.Endpoint,
      Keyword.merge(endpoint, server: false, http: false)
    )

    start_supervised!(AgentDbWeb.Endpoint)

    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart()

    on_exit(fn ->
      Application.put_env(:agent_db, AgentDbWeb.Endpoint, endpoint)
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  test "every console page carries the sidebar, its heading, and marks itself current" do
    for {path, heading} <- @pages do
      {:ok, _view, html} = live(build_conn(), path)

      assert html =~ ~r{<h1[^>]*>#{heading}</h1>}, "#{path} does not render its heading"

      # Every page is the same shell -- the sidebar, the content region, and the
      # flash host -- so a page cannot render without somewhere to show feedback.
      assert html =~ ~s{class="admin-content}, "#{path} is missing the shared shell"
      assert html =~ ~s{id="flash"}, "#{path} is missing the shared flash host"

      for href <- @nav do
        assert html =~ href, "#{path} is missing the #{href} link"
      end

      # The current page is the one link marked active, and the links carry the
      # marker the client uses to navigate inside the console without a reload.
      assert html =~ ~r{href="#{Regex.escape(path)}"[^>]*data-active}
      assert html =~ ~r{href="#{Regex.escape(path)}"[^>]*data-phx-link}
    end
  end

  test "the document editor keeps the sidebar, with Documents current" do
    uri = "viking://resources/nav/doc.md"
    :ok = AgentDb.write(uri, "nav content")

    {:ok, _view, html} = live(build_conn(), "/admin/documents/#{URI.encode_www_form(uri)}/edit")

    assert html =~ "nav content"

    assert html =~ ~s{class="admin-content}, "the editor is missing the shared shell"
    assert html =~ ~s{id="flash"}, "the editor is missing the shared flash host"

    for href <- @nav do
      assert html =~ href
    end

    assert html =~ ~r{href="/admin/documents"[^>]*data-active}
  end

  defp restart do
    Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
