import Config

# Production serves the browser-safe error pages rather than the debug ones.
# `cache_static_manifest` points at the digest map `mix assets.deploy` writes, so
# the pages' asset URLs resolve to the digested filenames that release serves.
# Secrets and the listener are resolved at boot in `runtime.exs`.
config :agent_db, AgentDbWeb.Endpoint,
  debug_errors: false,
  cache_static_manifest: "priv/static/cache_manifest.json"
