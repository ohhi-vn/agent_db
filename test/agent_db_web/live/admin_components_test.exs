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

  describe "the llm layers" do
    test "renders all three layers with source badges and char counts" do
      html =
        render_component(&AdminComponents.llm_layers/1, %{
          layers: %{
            l0: %{text: "one-line L0", source: :stored, chars: 11},
            l1: %{text: "structured L1", source: :fallback, chars: 13},
            l2: %{text: "full L2 body", source: :stored, chars: 12}
          }
        })

      assert html =~ "How the LLM sees this document"
      assert html =~ "Abstract (L0)"
      assert html =~ "Overview (L1)"
      assert html =~ "Full content (L2)"
      assert html =~ "one-line L0"
      assert html =~ "structured L1"
      assert html =~ "full L2 body"
      assert html =~ "stored"
      assert html =~ "fallback"
      assert html =~ "11 chars"
    end

    test "renders unavailable layers without breaking the others" do
      html =
        render_component(&AdminComponents.llm_layers/1, %{
          layers: %{
            l0: %{text: "", source: :unavailable, chars: 0},
            l1: %{text: "structured L1", source: :fallback, chars: 13},
            l2: %{text: "full L2 body", source: :stored, chars: 12}
          }
        })

      assert html =~ "Not available."
      assert html =~ "structured L1"
      assert html =~ "full L2 body"
    end

    test "long layers render an excerpt with the full text behind an expand" do
      long = String.duplicate("x", 600)

      html =
        render_component(&AdminComponents.llm_layers/1, %{
          layers: %{
            l0: %{text: "one-line L0", source: :stored, chars: 11},
            l1: %{text: "structured L1", source: :fallback, chars: 13},
            l2: %{text: long, source: :stored, chars: 600}
          }
        })

      assert html =~ "Show full Full content (L2)"
      assert html =~ String.slice(long, 0, 500)
      assert html =~ long
    end
  end
end
