# phoenix-web-ui Design

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    AgentDb.Application                        │
├─────────────────────────────────────────────────────────────┤
│  Supervisor (one_for_one)                                    │
│  ├── Cache.Owner                                              │
│  ├── Store.Writer                                             │
│  ├── Store.Reader                                             │
│  ├── ML.ModelManager                                          │
│  ├── Workers.EmbeddingWorker                                  │
│  ├── Workers.SummarizationWorker                              │
│  ├── Phoenix.PubSub (NEW)                                     │
│  └── AgentDbWeb.Endpoint (NEW — includes Router)             │
└─────────────────────────────────────────────────────────────┘
```

## New Modules

### 1. Router — `lib/agent_db_web/router.ex`

```elixir
defmodule AgentDbWeb.Router do
  use AgentDbWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
    plug :protect_from_forgery
    plug AgentDbWeb.Plugs.SessionAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug AgentDbWeb.Plugs.AuthPlug
    plug AgentDbWeb.Plugs.CORSPlug
  end

  scope "/", AgentDbWeb do
    pipe_through :browser
    live "/admin", AdminLive, :index
    live "/admin/documents/:id/edit", DocumentEditorLive, :edit
  end

  scope "/api/v1", AgentDbWeb.Controllers do
    pipe_through :api
    get "/health", HealthController, :show
    resources "/documents", DocumentController, except: [:new, :edit]
    post "/search", SearchController, :search
    get "/search/suggest", SearchController, :suggest
    resources "/sessions", SessionController, only: [:create, :show] do
      post "/messages", SessionController, :append_message
      post "/commit", SessionController, :commit
    end
    get "/models/status", ModelController, :status
  end

  if Mix.env() == :dev do
    scope "/dev", AgentDbWeb do
      pipe_through :browser
      forward "/dashboard", Phoenix.LiveDashboard, metrics: true
    end
  end
end
```

### 2. Endpoint — `lib/agent_db_web/endpoint.ex` (extends existing)

```elixir
defmodule AgentDbWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agent_db

  socket "/api", AgentDb.WebSocket  # existing WebSocket
  socket "/live", Phoenix.LiveView.Socket  # NEW: LiveView

  plug Plug.RequestId
  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["*/*"],
    json_decoder: Jason
  plug AgentDbWeb.Router  # NEW: mount router

  @impl true
  def init(_key, config) do
    {:ok, Keyword.put(config, :secret_key_base, "agent_db_dev_secret_key_base")}
  end
end
```

### 3. Controllers — `lib/agent_db_web/controllers/`

**Shared Context** — `lib/agent_db_web/context.ex`:
```elixir
defmodule AgentDbWeb.Context do
  alias AgentDb.{Store.Reader, Store.Writer, JobQueue, ML.ModelManager}
  alias AgentDb.Config

  def list_documents(opts \\ []) do
    # pagination, filtering
  end

  def get_document(uri) do
    Reader.read(uri)
  end

  def create_document(uri, content, opts \\ []) do
    Writer.write(uri, content, opts)
  end

  def update_document(uri, content, opts \\ []) do
    Writer.write(uri, content, opts)  # upsert
  end

  def delete_document(uri) do
    Writer.rm(uri)
  end

  def search_documents(term, opts \\ []) do
    AgentDb.search(term, opts)
  end

  def list_sessions(opts \\ []) do
    # query sessions from DB
  end

  def get_session(id) do
    AgentDb.get_session(id)
  end

  def model_status do
    ModelManager.model_status()
  end

  def health_check do
    %{db: check_db(), models: check_models()}
  end
end
```

**Controller Pattern** — all controllers delegate to Context:
```elixir
defmodule AgentDbWeb.Controllers.DocumentController do
  use AgentDbWeb, :controller
  alias AgentDbWeb.Context

  def index(conn, params) do
    with {:ok, result} <- Context.list_documents(params) do
      render(conn, "index.json", result)
    end
  end

  def show(conn, %{"id" => uri}) do
    with {:ok, content} <- Context.get_document(uri) do
      render(conn, "show.json", %{uri: uri, content: content})
    else
      {:error, _} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def create(conn, %{"document" => params}) do
    with {:ok, result} <- Context.create_document(params["uri"], params["content"], params["opts"] || []) do
      conn |> put_status(:created) |> json(result)
    else
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end
  # ... update, delete
end
```

### 4. Plugs — `lib/agent_db_web/plugs/`

**AuthPlug** — Bearer token validation:
```elixir
defmodule AgentDbWeb.Plugs.AuthPlug do
  import Plug.Conn
  alias AgentDb.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    if Config.http_auth() do
      case get_bearer_token(conn) do
        nil -> unauthorized(conn)
        token when token in Config.http_auth_tokens() -> conn
        _ -> unauthorized(conn)
      end
    else
      conn
    end
  end

  defp get_bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> (fn h -> Regex.run(~r/Bearer\s+(.+)/, h) end).()
    |> (fn [_, token] -> token end).()
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
```

**CORSPlug** — configurable origins:
```elixir
defmodule AgentDbWeb.Plugs.CORSPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first()
    if origin && origin_allowed?(origin) do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    else
      conn
    end
  end

  defp origin_allowed?(origin) do
    # Config.cors_origins() || ["*"]
    true  # TODO: make configurable
  end
end
```

**SessionAuth** — for LiveView:
```elixir
defmodule AgentDbWeb.Plugs.SessionAuth do
  import Plug.Conn
  alias AgentDb.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    # For now, allow all. Can add session-based auth later.
    conn
  end
end
```

### 5. LiveViews — `lib/agent_db_web/live/`

**AdminLive** — main dashboard with tabs:
```elixir
defmodule AgentDbWeb.AdminLive do
  use AgentDbWeb, :live_view
  alias AgentDbWeb.Context
  alias AgentDb.PubSub

  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe("documents")
      PubSub.subscribe("sessions")
      PubSub.subscribe("jobs")
    end
    {:ok, assign(socket, documents: load_documents(), active_tab: "documents")}
  end

  def handle_info({:doc_change, _uri}, socket) do
    {:noreply, assign(socket, documents: load_documents())}
  end
  # ... other pubsub handlers
end
```

**DocumentEditorLive** — editor with auto-save:
```elixir
defmodule AgentDbWeb.DocumentEditorLive do
  use AgentDbWeb, :live_view
  alias AgentDbWeb.Context

  def mount(%{"id" => uri}, _session, socket) do
    {:ok, content} = Context.get_document(uri)
    {:ok, assign(socket, uri: uri, content: content, draft: load_draft(uri))}
  end

  def handle_event("save_draft", %{"content" => content}, socket) do
    save_draft(socket.assigns.uri, content)
    {:noreply, assign(socket, draft: content)}
  end

  def handle_event("publish", %{"content" => content}, socket) do
    case Context.update_document(socket.assigns.uri, content, []) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Published") |> push_patch(to: ~p"/admin")}
      {:error, e} -> {:noreply, put_flash(socket, :error, e) |> assign(socket, draft: content)}
    end
  end
end
```

### 6. PubSub — `lib/agent_db/pub_sub.ex`

```elixir
defmodule AgentDb.PubSub do
  @moduledoc "PubSub for real-time updates"
  use Phoenix.PubSub, name: AgentDb.PubSub
end
```

Add to supervision tree in `Application.start/2`.

### 7. Assets

**assets/package.json**:
```json
{
  "dependencies": {
    "phoenix": "file:../deps/phoenix",
    "phoenix_html": "file:../deps/phoenix_html",
    "phoenix_live_view": "file:../deps/phoenix_live_view",
    "topbar": "^1.0.0"
  },
  "devDependencies": {
    "tailwindcss": "^3.4.0",
    "esbuild": "^0.20.0"
  }
}
```

**assets/js/app.js** — standard LiveView setup with topbar

**assets/css/app.css** — Tailwind imports

## Configuration

**config/config.exs**:
```elixir
config :agent_db, AgentDbWeb.Endpoint,
  http: [port: 4000],
  url: [host: "localhost", port: 4000],
  live_view: [signing_salt: "agent_db_live_view_salt"],
  pubsub: [name: AgentDb.PubSub, adapter: Phoenix.PubSub.PG2]
```

**config/runtime.exs** (production):
```elixir
config :agent_db, AgentDbWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")],
  url: [host: System.get_env("PHX_HOST") || "localhost", port: 4000],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SIGNING_SALT")]
```

## Data Flow

```
HTTP Request
    │
    ▼
┌─────────────────┐
│   Endpoint      │ ◄── Plug pipeline (RequestId, Logger, Parsers)
└────────┬────────┘
         ▼
┌─────────────────┐
│   Router        │ ◄── Pipeline (:browser or :api)
└────────┬────────┘
         ▼
┌─────────────────┐
│   Controller    │ ◄── AuthPlug, CORSPlug (api)
│   or LiveView   │
└────────┬────────┘
         ▼
┌─────────────────┐
│   Context       │ ◄── Business logic, calls AgentDb
└────────┬────────┘
         ▼
┌─────────────────┐
│   AgentDb       │ ◄── Store, ML, Workers
└─────────────────┘
```

## Real-time Updates

1. `AgentDb.Store.Writer` broadcasts on write/rm:
   ```elixir
   AgentDb.PubSub.broadcast("documents", {:doc_change, uri})
   ```

2. `AgentDb.Workers` broadcast on job completion:
   ```elixir
   AgentDb.PubSub.broadcast("jobs", {:job_complete, job_id})
   ```

3. LiveViews subscribe in `mount/3` and handle in `handle_info/2`

## Testing Strategy

- **Controller tests**: `AgentDbWeb.Controllers.DocumentControllerTest` — test each action with valid/invalid params
- **LiveView tests**: `AgentDbWeb.AdminLiveTest` — test mount, handle_event, PubSub updates
- **Integration tests**: Full HTTP request/response cycles
- **Plug tests**: AuthPlug, CORSPlug in isolation

## Migration from Existing WebSocket

The existing `AgentDb.WebSocket` and `AgentDb.WebChannel` remain unchanged at `/api` socket. New HTTP routes at `/api/v1/*` provide REST alternative. Both share the same `AgentDb` context functions.

## Security Considerations

- All API endpoints require Bearer token when `http_auth` enabled
- LiveView uses session auth (CSRF protected by default)
- CORS restricted to configured origins
- Rate limiting can be added via plug (future)
- Input validation in controllers via Ecto schemas or custom validation

## Rollout Plan

1. Add deps, config, assets
2. Implement Router, Endpoint, Context
3. Implement Controllers + tests
4. Implement Plugs
5. Implement LiveViews + tests
5. Add PubSub to supervision tree
6. Verify `mix test` passes
7. Verify `mix assets.build` works
8. Document in README