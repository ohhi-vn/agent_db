# Runtime configuration for AgentDb (evaluated at boot time)
import Config

# This file is evaluated at runtime, not compile time.
# Use for configuration that requires runtime evaluation (e.g., secrets from vault).

# Serving, port and bind address apply in every environment.
#
# `server: true` is the switch that actually opens a listener. Without it Phoenix
# starts the endpoint child and binds nothing, and says so only when RELEASE_NAME
# is set -- so under `mix run` and `iex -S mix` the surface is silently absent.
#
# The bind defaults to loopback: the HTTP surface is unauthenticated by design,
# and it exposes document and memory content, so it should not land on every
# interface unless an operator asks for it.
http_port = String.to_integer(System.get_env("AGENT_DB_HTTP_PORT") || "6060")

http_ip =
  case System.get_env("AGENT_DB_HTTP_IP") do
    nil ->
      {127, 0, 0, 1}

    value ->
      case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
        {:ok, ip} -> ip
        {:error, _} -> raise "AGENT_DB_HTTP_IP is not a valid IP address: #{inspect(value)}"
      end
  end

config :agent_db, AgentDbWeb.Endpoint,
  server: true,
  http: [ip: http_ip, port: http_port],
  # Derived from the same resolved port, so URL generation cannot disagree with
  # the port actually being served.
  url: [host: System.get_env("PHX_HOST") || "localhost", port: http_port]

# Report the resolved bind interface to application code, so Config.http_ip/0
# and the endpoint cannot disagree about which interface is in force.
config :agent_db, :http_ip, http_ip

if config_env() == :prod do
  # Port and bind come from AGENT_DB_HTTP_PORT / AGENT_DB_HTTP_IP above, so a
  # deployment sets one variable rather than two that can disagree. PORT is
  # deliberately not read: it would appear to work while the compiled-in
  # default continued to be served.
  config :agent_db, AgentDbWeb.Endpoint,
    secret_key_base: System.get_env("SECRET_KEY_BASE"),
    live_view: [signing_salt: System.get_env("LIVE_VIEW_SIGNING_SALT")]
end
