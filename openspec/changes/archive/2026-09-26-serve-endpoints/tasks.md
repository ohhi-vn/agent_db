# Tasks

## 1. Configuration

- [x] 1.1 Add an `http_ip/0` accessor to `lib/agent_db/config.ex` reading `AGENT_DB_HTTP_IP` and defaulting to `{127, 0, 0, 1}` — verify `AgentDb.Config.http_ip()` returns loopback with no env var set
- [x] 1.2 Default `http_enabled` to `false` when `Mix.env() == :test` in `put_default_config/0` in `lib/agent_db/application.ex`, leaving other environments at the existing `AGENT_DB_HTTP_ENABLED` default — verify the endpoint child is absent from `AgentDb.Supervisor`'s children under `MIX_ENV=test` and present otherwise
- [x] 1.3 Set `server: true` and the `ip:`/`port:` pair on the `AgentDbWeb.Endpoint` configuration in `config/runtime.exs` for every environment, reading `AGENT_DB_HTTP_PORT` and `AGENT_DB_HTTP_IP` — verify `AgentDbWeb.Endpoint.config(:server)` is `true` and `config(:http)` carries the configured port and loopback bind

## 2. Single port source

- [x] 2.1 Stop reading `PORT` for the endpoint port in the `config_env() == :prod` block of `config/runtime.exs`, leaving `AGENT_DB_HTTP_PORT` as the only port input — verify a boot with `AGENT_DB_HTTP_PORT` set serves on that port and `PORT` no longer influences it
- [x] 2.2 Delete `Config.http_port/0` and its `@spec`, which has no callers — verify `mix compile` succeeds and `grep -rn "http_port()" lib/` returns nothing
- [x] 2.3 Update the README's HTTP configuration section to document `AGENT_DB_HTTP_PORT` and `AGENT_DB_HTTP_IP`, state that the bind defaults to loopback, and note that `PORT` is no longer read — verify the documented variables match the values read in `runtime.exs`

## 3. Supervision tree

- [x] 3.1 Add `{Phoenix.PubSub, name: AgentDb.PubSub}` to the children in `lib/agent_db/application.ex`, ahead of the endpoint — verify `Process.whereis(AgentDb.PubSub)` returns a pid after the application starts
- [x] 3.2 Verify `Phoenix.PubSub.subscribe(AgentDb.PubSub, "probe")` succeeds from a process outside the endpoint — verify a subscription is registered and the call does not raise
- [x] 3.3 Delete `lib/agent_db/web/endpoint.ex` (`AgentDb.WebEndpoint`), the unsupervised duplicate endpoint that pins `secret_key_base` — verify `mix compile` succeeds and no module named `AgentDb.WebEndpoint` remains

## 4. Serving

- [x] 4.1 Verify with HTTP enabled that a TCP listener is open on the configured port — verify `lsof -nP -iTCP:<port> -sTCP:LISTEN` reports the node while the application runs
- [x] 4.2 Verify the default listener is bound to loopback and not to a non-loopback interface — verify a request to `127.0.0.1:<port>` is answered and a request to the machine's LAN address on that port is refused
- [x] 4.3 Verify a request to the configured port is answered rather than refused — verify `GET /api/v1/health` returns a response body. It answers 503 with `{"status":"degraded"}` when models are unloaded, which is the controller's deliberate behaviour (`if status == "ok", do: 200, else: 503`); the requirement is that the request is answered, not that it is 2xx
- [x] 4.4 Verify that with HTTP disabled no listener is open — verify a request to the configured port is refused while the store remains otherwise operational

## 5. Regression test

- [x] 5.1 Add a reachability test that enables HTTP on a dedicated test port, restarts the application, makes a real request, and asserts a response — verify the test passes with `server: true` present
- [x] 5.2 Verify the reachability test fails when `server: true` is removed from the endpoint configuration, and record the failure mode — done: with the key removed the suite drops to 5/8, the two behavioural tests fail on `:refused` (`get/2` returns `:refused` where `{:ok, status}` is expected) and the configuration test fails on `server: true`. Restored afterwards
- [x] 5.3 Confirm the full suite still passes with the listener fix applied and the surface off by default under test — verify `mix test` reports no failures and no setup block contends for a port

## 6. Documentation

- [x] 6.1 Record in the README that the HTTP surface serves on the configured port and binds loopback by default, and that `AGENT_DB_HTTP_ENABLED=false` starts the store with no listener — verify the claims match `runtime.exs` and `application.ex`
- [x] 6.2 Note in the README that the operations console and `/admin` are known-broken and are the subject of the following change, so a reader who can now reach `/admin` is not left to guess why it errors — verify the note names `/admin` and its missing render clause
