# Compile-time configuration for AgentDb
import Config

# Endpoint configuration
#
# Port, bind interface, `server:` and `url:` are all set in config/runtime.exs,
# which resolves them from AGENT_DB_HTTP_PORT and AGENT_DB_HTTP_IP at boot. They
# are not set here: a compile-time value would be a second port setting that
# silently disagreed with the one actually served.
config :agent_db, AgentDbWeb.Endpoint,
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