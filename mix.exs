defmodule AgentDb.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :agent_db,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: "Embedded offline context store for AI agents",
      source_url: "https://github.com/manhvu/agent_db",
      # The file set is declared rather than inferred. Hex's default selection
      # is "everything git tracks that is not ignored", and `models/` is
      # tracked here, so the default package would ship model binaries.
      package: package(),
      docs: docs(),
      # The support modules are required by `test_helper.exs` rather than
      # compiled, so that a single-file `mix test path/to/one_test.exs` run has
      # them too. Without this, Mix warns that they match no test filter.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      # The PLT is left at Dialyxir's default path under `_build`, so caching
      # `_build` caches it and no PLT artifact can reach the package.
      dialyzer: [plt_add_apps: [:mix, :ex_unit], ignore_warnings: ".dialyzer_ignore.exs"],
      aliases: aliases(),
      deps: deps()
    ]
  end

  # One definition of each gate, so the command a developer runs is the command
  # CI runs. Dialyzer is left out of `lint:quick` because its PLT analysis
  # dominates the runtime; `mix docs` needs no alias, as `ex_doc` provides it.
  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      "lint:quick": ["format --check-formatted", "credo --strict"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AgentDb.Application, []}
    ]
  end

  # What a consumer receives. Verified by building the package and listing the
  # tarball rather than by reading this list; `.github/workflows/verify.yml`
  # asserts both directions on every run.
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/manhvu/agent_db",
        "Docs" => "https://hexdocs.pm/agent_db"
      },
      files: [
        "lib",
        "config",
        "priv/static",
        "mix.exs",
        "README.md",
        "LICENSE",
        "docs"
      ]
    ]
  end

  # The generated reference covers what a consumer writes against: the facade,
  # the ports it is written against, the web layer, the model backends, the
  # archive codec, and the CLI. Everything else -- the application workflows,
  # the SQLite adapter, the cache, configuration -- is marked
  # `@moduledoc false`, which is the codebase's existing way of saying a module
  # is internal, and ExDoc leaves those out.
  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "LICENSE",
        "docs/QUICKSTART.md",
        "docs/SETUP.md",
        "docs/USAGE.md",
        "docs/agents.md"
      ],
      groups_for_modules: [
        "Context store": [AgentDb, AgentDb.Core.Storage, AgentDb.Core.Transport, AgentDb.Archive],
        "Inference and models": [AgentDb.Core.Inference, AgentDb.ML],
        "Background work and diagnostics": [AgentDb.JobQueue, AgentDb.Observability],
        "Agent skills": [AgentDb.Skills],
        "HTTP, WebSocket and MCP": [AgentDbWeb],
        "Command line": [Mix.Tasks.AgentDb]
      ]
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
      {:telemetry, "~> 1.0"},
      {:opentelemetry_api, "~> 1.5"},
      {:benchee, "~> 1.0", only: [:dev, :test], runtime: false},
      {:opentelemetry, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      # Asset and model-backend tooling. These declare `build_tools: ["mix"]`
      # (plus "make" for the two Metal backends) in their own Hex metadata, so
      # Mix compiles them correctly without a `manager:` override here -- and a
      # package carrying `manager:` is one Hex refuses to build or publish.
      {:tailwind, "~> 0.5", runtime: false},
      {:esbuild, "~> 0.10", runtime: false},
      {:emlx, "~> 0.5", optional: true, runtime: false},
      {:emlx_axon, "~> 0.5", optional: true, runtime: false},
      # LiveView's own test helpers parse the rendered DOM, which is what the
      # console's upload forms and result reports are asserted against.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
