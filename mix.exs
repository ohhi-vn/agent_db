defmodule AgentDb.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_db,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AgentDb.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exqlite, "~> 0.41"},
      {:exla, "~> 1.0"},
      {:bumblebee, "~> 0.8"},
      {:nx, "~> 1.0"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_pubsub, "~> 2.3"},
      {:phoenix_view, "~> 2.0"},
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.7"},
      {:tailwind, "~> 0.5", runtime: false, manager: :mix},
      {:esbuild, "~> 0.10", runtime: false, manager: :mix},
      {:emlx, "~> 0.5", runtime: false, manager: :mix, override: true},
      {:emlx_axon, "~> 0.5", optional: true, runtime: false, manager: :mix},
      # LiveView's own test helpers parse the rendered DOM, which is what the
      # console's upload forms and result reports are asserted against.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
