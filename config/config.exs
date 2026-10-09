# Compile-time configuration for AgentDb
import Config

# Endpoint configuration
#
# Port, bind interface, `server:` and `url:` are all set in config/runtime.exs,
# which resolves them from AGENT_DB_HTTP_PORT and AGENT_DB_HTTP_IP at boot. They
# are not set here: a compile-time value would be a second port setting that
# silently disagreed with the one actually served.
# 64 bytes, which is what Plug's cookie session store requires: a shorter one
# makes every browser request -- the console included -- fail with a 500 before
# a route is even reached. Production reads SECRET_KEY_BASE instead.
config :agent_db, AgentDbWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  live_view: [signing_salt: "agent_db_live_view_salt"],
  pubsub_server: AgentDb.PubSub,
  secret_key_base: "agent_db_dev_secret_key_base_for_the_console_and_the_api_surface"

# LiveView configuration
config :phoenix, :live_view, signing_salt: "agent_db_live_view_salt"

# Log formatting
#
# The default formatter hides metadata, so the structured fields the store logs
# -- component, operation, outcome, reason, and trace/job correlation -- would
# never reach the console. Naming them here is what makes a structured log
# readable rather than a bare "agent_db".
config :logger, :default_formatter,
  metadata: [
    :component,
    :operation,
    :kind,
    :role,
    :outcome,
    :reason,
    :trace_id,
    :span_id,
    :job_id
  ]

# Tailwind configuration
#
# The profile carries CLI `args` and a working directory, which is the interface
# the `tailwind` task reads. Older `config:`/`css:` keys are ignored by the task,
# which then runs with no input or output and writes nothing -- the reason the
# committed stylesheet had gone stale.
config :tailwind,
  version: "3.4.0",
  default: [
    args:
      ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: "assets"
  ]

# Esbuild configuration
config :esbuild,
  version: "0.20.0",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: "assets"
  ]

# The dev LiveDashboard's configuration lives on its route in
# `lib/agent_db_web/router.ex`; the dependency reads no `:live_dashboard`
# application env, so no entry is kept here.

# Environment-specific configuration. Each file declares only what differs for
# that environment; `config.exs` above holds what every environment shares.
import_config "#{config_env()}.exs"
