# Design

## Context

See `proposal.md` — Why. The mechanics that shape the approach:

- `Phoenix.Endpoint.Supervisor.server?/2` resolves to `Keyword.get_lazy(conf, :server, fn -> Application.get_env(:phoenix, :serve_endpoints, false) end)`. With no `:server` key and no `:serve_endpoints`, that is `false`, and `server_children/3` returns `[]` for the HTTP case without logging unless `RELEASE_NAME` is set.
- `AgentDb.Application.start/2` already gates the endpoint child on `Config.http_enabled/0`, which `put_default_config/0` derives from `AGENT_DB_HTTP_ENABLED` and defaults to `true`.
- `Config.http_port/0` has a `@spec` and **no callers**. The port that would actually be served comes from `config/runtime.exs`, which independently reads `PORT`. Two knobs, one inert.
- `config/config.exs` sets `pubsub_server: AgentDb.PubSub`, but neither supervision tree starts that server.
- There is no `config/test.exs`, and `config.exs` contains no `import_config`. `runtime.exs` runs in every environment but currently guards its only block on `config_env() == :prod`.
- Seventeen setup blocks across five test files call `Application.stop/1` then `ensure_all_started/1`, so the application — and therefore any listener — is restarted seventeen times per suite run.
- `lib/agent_db/web/endpoint.ex` defines `AgentDb.WebEndpoint`, a second endpoint declaring the same `/api` socket, never supervised, and pinning `secret_key_base` to a literal.

## Goals / Non-Goals

**Goals:**
- A request to the configured port is answered, in every environment where HTTP is enabled.
- Enabling HTTP and serving HTTP stop being the same claim.
- One port value determines the port served, and it is the library's own knob.
- Loopback by default, so an unauthenticated surface is not on every interface by accident.
- A regression in any of the above fails a test rather than passing silently.

**Non-Goals:**
- No authentication. This is a single-operator surface; that is a deliberate product decision, not an oversight, and the loopback default is what makes it defensible.
- No TLS. Left to the deployer, as Phoenix expects.
- No telemetry, no operations console, no repair of `AdminLive`.
- No change to the endpoint's plugs, sockets, or router.

## Decisions

### 1. Enable serving through the endpoint's own configuration

**Decision**: Set `server: true` on the `AgentDbWeb.Endpoint` configuration, rather than starting a listener by some other means.

**Rationale**: `server?` is Phoenix's master switch and the only supported way to open a listener. The defect was a missing key in the place Phoenix reads it from, so the fix belongs in the same place. Anything else — a hand-started listener, a second endpoint — would leave `server?` false and the configuration still lying about what is served.

**Alternatives considered**:
- *Set `config :phoenix, :serve_endpoints, true`* — rejected. It is a global fallback for every endpoint in the VM, including any a host application adds, and it fixes the symptom rather than the endpoint's own configuration.
- *Start `AgentDb.WebEndpoint` instead, since it already exists* — rejected. It is unsupervised, hardcodes `secret_key_base`, and duplicating the surface would make the port and secret situation worse.

### 2. Keep "should the endpoint run" separate from "what should it serve"

**Decision**: `Config.http_enabled/0` keeps its existing job — deciding whether the endpoint is supervised at all. Port, bind interface and `server: true` live in the endpoint's configuration and are not routed through `Config`.

**Rationale**: These are two different questions with two different reasons to change. Whether to run the endpoint is a library-level policy; what to serve is Phoenix configuration, and `runtime.exs` already exists to express it. Funnelling endpoint transport settings through `AgentDb.Config` would put Phoenix's schema inside the library and make `Config` the place to look for something Phoenix owns.

**Alternatives considered**:
- *Grow `put_default_config/0` to configure the endpoint* — rejected. It is the right home for library defaults read from the environment, and the wrong home for an endpoint's own schema; the two would then be indistinguishable.

### 3. One port source: retire the inert knob, keep the library's env name

**Decision**: Delete `Config.http_port/0`, which has no callers. Read `AGENT_DB_HTTP_PORT` in `runtime.exs` where the endpoint configuration is built, and stop reading `PORT`. Add `AGENT_DB_HTTP_IP` for the bind interface.

**Rationale**: `AGENT_DB_HTTP_PORT` is the name the README documents, so keeping it avoids breaking the documented contract; the fact that it was never wired is the bug, not the name. `PORT` is the conventional release variable and reading it here meant a deployment setting `PORT` correctly would still get a listener on a hardcoded `4000` from `config.exs`, which is the worst outcome — a setting that appears to work and does not.

**Alternatives considered**:
- *Keep `PORT` and drop `AGENT_DB_HTTP_PORT`* — rejected. It breaks the documented name and makes a library depend on a release convention it does not own.
- *Keep `Config.http_port/0` and wire it in* — rejected. It would mean the endpoint reads its port out of a library function, which is decision 2.

### 4. Loopback by default

**Decision**: `ip: {127, 0, 0, 1}` unless `AGENT_DB_HTTP_IP` names another interface.

**Rationale**: The surface is unauthenticated by decision, and it exposes the document corpus, memory values, session identifiers and model state. `config.exs` already declares `url: [host: "localhost"]`, so local access is what was intended; the bind address simply was not constrained to match, which is why a listener on all interfaces would be the default outcome. Constraining the bind is a configuration default, not a feature, and it is free today precisely because nothing is currently listening.

**Alternatives considered**:
- *Leave the bind unset* — rejected. That binds every interface, which contradicts the declared `url` host and is unsafe for an unauthenticated surface.
- *Require the operator to set an interface* — rejected. It makes the safe configuration the one that requires action, and the store serves nothing by default today, so the safe configuration should also be the default one.

### 5. Start the PubSub server the configuration already names

**Decision**: Add `{Phoenix.PubSub, name: AgentDb.PubSub}` to the supervision tree, ahead of the endpoint.

**Rationale**: `config.exs` already declares `pubsub_server: AgentDb.PubSub`. Subscribing to a name with no server raises, so the LiveView's `subscribe` calls are a guaranteed failure once the surface is reachable, and `Real-time subscriptions` cannot be satisfied at all. Declaring a dependency and not starting it is the same class of defect as the listener: configuration that does not correspond to reality.

**Alternatives considered**:
- *Remove `pubsub_server` from the configuration instead* — rejected. Real-time subscriptions and the forthcoming operations console both need it, and removing it makes a stated requirement unsatisfiable rather than fixing the omission.

### 6. Under test, no listener unless a test asks for one

**Decision**: Default `http_enabled` to `false` when `Mix.env() == :test`. One dedicated reachability test sets it to `true` with its own port, restarts the application, makes a real request, and asserts the response.

**Rationale**: This is a new risk introduced by fixing the defect, and it has to be designed for rather than discovered. Seventeen setup blocks restart the application; with a listener enabled they would each bind a port, and a conflict with a development instance already on that port would make the endpoint fail to start and take the entire suite down with it. The existing tests exercise the store and need no HTTP, so having the surface off by default under test costs them nothing and removes seventeen points of contention.

**Alternatives considered**:
- *Leave it enabled and give the suite a fixed port* — rejected. A fixed port is a shared resource across concurrent runs and against any running development instance; the failure mode is a suite that cannot start, for a reason unrelated to what it is testing.
- *Assert only on `Phoenix.Endpoint.Supervisor.server?/2`* — rejected as the sole check. It asserts the mechanism rather than the behaviour, and the original defect lived in exactly that mechanism. A real request is the assertion that would have caught it.

### 7. Remove the duplicate endpoint

**Decision**: Delete `lib/agent_db/web/endpoint.ex` (`AgentDb.WebEndpoint`).

**Rationale**: It is unsupervised, declares the same `/api` socket as the live endpoint, and pins `secret_key_base` to a literal — so a reader comparing the two files has no way to tell which one is authoritative, and the one that looks standalone is the one that would leak a hardcoded secret into any configuration derived from it. It is separable: striking this item leaves the listener fix intact.

**Alternatives considered**:
- *Keep it and mark it deprecated* — rejected. It has no callers, so a deprecation path would be for code that does not exist.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Enabling the listener turns silent non-reachability into visible errors — `/admin` will answer with a crash rather than refuse, because its missing `render/1` is a separate defect | Accepted and stated in the proposal. A visible failure is strictly better than a silent one, and it is the reason the next defect was findable at all. The console is the following change. |
| Dropping the `PORT` read breaks a deployment that sets it | Called out as **BREAKING** in the proposal. The alternative was a setting that appears to work and does not, which is worse to operate. A deployment setting `PORT` must move to `AGENT_DB_HTTP_PORT`. |
| Binding loopback breaks a deployment currently reaching the surface over a network | It cannot be reaching it — nothing listens today. The risk applies only to a deployment that sets `AGENT_DB_HTTP_IP` after this change and is documented in the README. |
| The reachability test's port could still collide | A dedicated test port, and the surface is off by default under test, so the only test that binds is the one that asserts on it. |
| `server?` remains Phoenix's silent-by-default switch, so a future config edit could remove `server: true` and regress | The reachability test fails if it does. This is the specific reason decision 6 insists on a real request rather than a configuration assertion. |

## Migration Plan

1. Add the bind-interface accessor and default `http_enabled` to `false` under test.
2. Set `server: true`, the loopback bind, and the `AGENT_DB_HTTP_PORT` / `AGENT_DB_HTTP_IP` reads in `runtime.exs`; start `Phoenix.PubSub` in the supervision tree.
3. Delete `Config.http_port/0` and `lib/agent_db/web/endpoint.ex`.
4. Add the reachability test.
5. Update the README's HTTP configuration section.

No schema change, no data migration, no new dependency, and nothing to reverse in user data. Rollback is reverting the change; a rollback returns the surface to not serving, which is the current state.

## Open Questions

None. The remaining unknowns — whether the operations console should be one surface or two, and what it should measure — belong to the following change and do not constrain this one.
