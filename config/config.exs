# Compile-time configuration for AgentDb
import Config

# Endpoint configuration
config :agent_db, AgentDbWeb.Endpoint,
  http: [port: 4000],
  url: [host: "localhost", port: 4000],
  live_view: [signing_salt: "agent_db_live_view_salt"],
  pubsub_server: AgentDb.PubSub,
  secret_key_base: "agent_db_dev_secret_key_base"

# LiveView configuration
config :phoenix, :live_view,
  signing_salt: "agent_db_live_view_salt"

# Tailwind configuration
config :tailwind,
  version: "3.4.0",
  default: [
    config: "assets/tailwind.config.js",
    css: "assets/css/app.css"
  ]

# Esbuild configuration
config :esbuild,
  version: "0.20.0",
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: "assets"
  ]

# Phoenix LiveDashboard (dev only)
config :agent_db, :live_dashboard,
  metrics: true