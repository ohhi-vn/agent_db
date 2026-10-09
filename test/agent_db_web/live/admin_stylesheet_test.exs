defmodule AgentDbWeb.AdminStylesheetTest do
  @moduledoc """
  The console's committed stylesheet.

  The console renders from utility classes over a base reset. If the reset is
  dropped, the browser's own body margin, list markers, and form-control defaults
  leak through, and the pages look unstyled even though their markup is correct.
  This asserts the committed artifact carries the reset and the classes the
  console uses, so `mix assets.build` cannot silently regress to that state.
  """
  use ExUnit.Case, async: false

  @stylesheet Path.join([File.cwd!(), "priv", "static", "assets", "app.css"])

  setup_all do
    %{css: File.read!(@stylesheet)}
  end

  describe "the committed stylesheet" do
    test "carries Tailwind's base reset", %{css: css} do
      # The first preflight rule: every element is border-box with no default
      # border. Without it, widths and spacing render differently.
      assert css =~ "box-sizing: border-box"
    end

    test "carries the classes the console uses", %{css: css} do
      assert css =~ ".space-y-8"
      assert css =~ ".grid-cols-5"
      assert css =~ ".font-mono"
    end
  end

  describe "the error pages" do
    # The pages build their asset URL through the endpoint's `static_path/1`,
    # which needs the endpoint's persistent term set, so the endpoint is started
    # without a listener for the render.
    setup do
      endpoint = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

      Application.put_env(
        :agent_db,
        AgentDbWeb.Endpoint,
        Keyword.merge(endpoint, server: false, http: false)
      )

      start_supervised!(AgentDbWeb.Endpoint)

      on_exit(fn -> Application.put_env(:agent_db, AgentDbWeb.Endpoint, endpoint) end)

      :ok
    end

    test "link the console stylesheet and render its classes" do
      for template <- ["404.html", "500.html"] do
        html = render_error_page(template)

        assert html =~ "/assets/app.css",
               "#{template} does not link the console stylesheet"

        assert html =~ "bg-gray-50",
               "#{template} does not use the console's classes"
      end
    end
  end

  defp render_error_page(template) do
    Phoenix.View.render_to_string(AgentDbWeb.ErrorView, template, %{})
  end
end
