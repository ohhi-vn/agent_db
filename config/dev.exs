import Config

# The development server. Source and templates reload as they change, and the
# console's stylesheet and scripts are rebuilt by the same Tailwind and esbuild
# profiles `mix assets.build` runs, so a change is visible without restarting.
config :agent_db, AgentDbWeb.Endpoint,
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--watch)]},
    tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css)$",
      ~r"lib/agent_db_web/.*(ex|heex)$"
    ]
  ]
