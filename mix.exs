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
      {:exqlite, "~> 0.40"},
      {:exla, "~> 0.7"},
      {:bumblebee, "~> 0.6"},
      {:nx, "~> 0.9"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_view, "~> 2.0"},
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:tailwind, "~> 0.2", runtime: false, manager: :mix},
      {:esbuild, "~> 0.7", runtime: false, manager: :mix}
    ]
  end
end
