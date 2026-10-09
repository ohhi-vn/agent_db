defmodule AgentDbWeb.AdminComponentsTest do
  @moduledoc """
  The console's navigation.

  The sidebar is the one place the console's pages are listed, so these assert
  that every page is reachable from it and that the page being shown is the one
  marked active.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AgentDbWeb.AdminComponents

  @pages [
    {"Overview", "/admin"},
    {"Documents", "/admin/documents"},
    {"Storage", "/admin/storage"},
    {"Skills", "/admin/skills"},
    {"Sessions", "/admin/sessions"}
  ]

  test "lists every console page" do
    html = render_component(&AdminComponents.sidebar/1, %{active: :overview})

    for {label, href} <- @pages do
      assert html =~ label
      assert html =~ href
    end
  end

  test "marks the page currently shown" do
    html = render_component(&AdminComponents.sidebar/1, %{active: :storage})

    assert html =~ ~r{href="/admin/storage"[^>]*data-active}
    refute html =~ ~r{href="/admin/documents"[^>]*data-active}
  end

  describe "the flash group" do
    test "renders each entry a page set" do
      html =
        render_component(&AdminComponents.flash_group/1, %{
          flash: %{"info" => "Published", "error" => "Could not publish: invalid_uri"}
        })

      assert html =~ ~s{id="flash"}
      assert html =~ "Published"
      assert html =~ "Could not publish: invalid_uri"
    end

    test "keeps an empty host when a page set no feedback" do
      html = render_component(&AdminComponents.flash_group/1, %{flash: %{}})

      assert html =~ ~s{id="flash"}
      refute html =~ "rounded border"
    end
  end
end
