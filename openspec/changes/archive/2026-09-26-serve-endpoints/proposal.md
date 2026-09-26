# Proposal

## Why

`agent_db` has never served a single HTTP request, in any environment. The Phoenix endpoint is mounted in the supervision tree and its supervisor reports the child as started, but Phoenix only opens a listener when `server: true` is configured — and no configuration file sets it. `server?/2` falls back to `Application.get_env(:phoenix, :serve_endpoints, false)`, which is `false`, so the endpoint starts and binds nothing. The failure is silent: Phoenix logs a hint only when `RELEASE_NAME` is set, so under `mix run` and under `iex -S mix` there is no warning at all. On a running dev node nothing listens on the configured port, and a request to loopback or to the machine's LAN address is refused.

This is the root cause of a cluster of defects that look unrelated. `AdminLive` has no `render/1` clause, so `/admin` cannot render. `AgentDb.PubSub` is named by the endpoint config but never started, so the LiveView's `subscribe` calls would raise. Nothing broadcasts `:doc_change`, `:session_change` or `:job_change`, because nobody could ever have listened. `model.last_latency_ms` is rendered but never produced, and `model_status/0` reports a hardcoded queue depth. `test/agent_db/web/channel_error_test.exs` passes throughout, because it exercises `AgentDb.WebChannel` as a module rather than over a socket. None of these are separate bugs; they are consequences of the surface having never been reachable.

The `http-api` capability has six requirements built on a client connecting to a WebSocket and calling `write/2`. None has ever been exercised. This change makes the store actually listen, and states the listener's lifecycle, bind address and port configuration as behaviour so the same silent failure cannot return unnoticed.

## What Changes

- **Open a listener when HTTP is enabled.** The endpoint SHALL serve, not merely start. Currently `Config.http_enabled/0` decides whether the endpoint child is supervised, and that is treated as equivalent to serving, which it is not.
- **Bind loopback by default, and make the interface configurable.** An unauthenticated console reachable on all interfaces is not a safe default for a store holding documents and memories. `AGENT_DB_HTTP_IP` selects a different interface when a private network is intended.
- **Collapse the duplicate port configuration to one source.** `Config.http_port/0` reads `AGENT_DB_HTTP_PORT`, while `config/runtime.exs` independently reads `PORT` for the same endpoint. Only the latter reaches Phoenix, so `AGENT_DB_HTTP_PORT` is currently inert. One library-owned knob replaces both.
- **Start the `Phoenix.PubSub` server the endpoint already declares.** `config/config.exs` sets `pubsub_server: AgentDb.PubSub` but no supervision tree starts it, so subscribing raises. This also unblocks the `Real-time subscriptions` requirement.
- **Add a reachability test.** Boot the endpoint and make a real request, so a regression fails loudly instead of silently. This is the specific gap that let the original defect survive a 159-test suite.
- **Remove `AgentDb.WebEndpoint`, an unused duplicate endpoint.** `lib/agent_db/web/endpoint.ex` defines a second endpoint for the same `/api` socket, is never supervised, and hardcodes `secret_key_base`. It is a trap for whoever next edits the endpoint. *This item is separable from the rest and can be struck without affecting the listener fix.*

Not in scope: telemetry emission, the operations console, and hybrid-search instrumentation. Those remain separate work. Two existing `http-api` requirements are still unmet after this change and are called out under Impact rather than fixed here: `Model status and health endpoints` asks for last inference latency and queue depth, neither of which is currently reported truthfully, and it is worth noting that the `AgentDb.PubSub` fix above is what makes `Real-time subscriptions` possible at all without that requirement's own scenarios being re-verified.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `http-api`: add a requirement covering the HTTP listener's lifecycle, its default bind address, and a single port configuration source. The existing requirements — including `WebSocket gateway for all store operations`, whose scenarios already assume a client can connect — are left unchanged, because they already state the required behaviour correctly; this change makes the code conform rather than restating the contract.

## Impact

- **Code:** `config/config.exs` — add `server: true` and a loopback bind for development, and the bind interface. `config/runtime.exs` — set `server: true` for production and stop reading `PORT` in favour of the library's own port configuration. `lib/agent_db/application.ex` — start `{Phoenix.PubSub, name: AgentDb.PubSub}` in the supervision tree. `lib/agent_db/config.ex` — add the bind-interface accessor. `lib/agent_db/web/endpoint.ex` — remove the unused duplicate endpoint module.
- **Behavior:** this is the first change that makes the HTTP surface reachable, so the web layer stops refusing connections and starts answering them. A client that previously got a connection error may now receive a response, and for `AdminLive` that response will be an error page rather than a refused connection, because its missing `render/1` is a separate defect. That is a deliberate trade: a visible failure is preferable to a silent one, and fixing the console is the next change.
- **Configuration:** `AGENT_DB_HTTP_PORT` becomes effective where it was previously inert. `PORT` is no longer read, so a deployment relying on it must move to `AGENT_DB_HTTP_PORT`. **BREAKING** for any such deployment. `AGENT_DB_HTTP_IP` is new and defaults to loopback.
- **No schema change, no data migration, no new dependency.**
- **Tests:** the reachability test is the only new test, and it is the one that matters — it converts an invisible failure into a failing build. `channel_error_test.exs` is unaffected and continues to pass.
