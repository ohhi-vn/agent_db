import Config

# The test suite is serial and reaches shared state, so its per-test logs are
# quieted to the failures that matter. The listener is not started in test:
# `AgentDb.Application` defaults `http_enabled` to false here and gates the
# endpoint's child spec on it, so no port is bound unless a test turns it on.
config :logger, level: :warning
