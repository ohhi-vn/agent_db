# Runtime configuration for AgentDb (evaluated at boot time)
import Config

# This file is evaluated at runtime, not compile time.
# Use for configuration that requires runtime evaluation (e.g., secrets from vault).

if config_env() == :prod do
  config :agent_db, AgentDbWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT") || "4000")],
    url: [host: System.get_env("PHX_HOST") || "localhost", port: 4000],
    secret_key_base: System.get_env("SECRET_KEY_BASE"),
    live_view: [signing_salt: System.get_env("LIVE_VIEW_SIGNING_SALT")]
end