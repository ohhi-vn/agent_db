defmodule AgentDbWeb.Router do
  @moduledoc """
  The HTTP surface.

  Two pipelines, because there are two kinds of client: an operator on the
  machine the store runs on, browsing a console, and a program reaching the
  store over the network. The API pipeline authenticates and answers JSON; the
  browser pipeline renders pages. Both reach the store only through the facade.
  """
  use AgentDbWeb, :router

  import Phoenix.LiveView.Router

  alias AgentDbWeb.{AuthPlug, CORSPlug, SessionAuth}

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_secure_browser_headers)
    plug(:protect_from_forgery)
    plug(SessionAuth)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(AuthPlug)
    plug(CORSPlug)
  end

  scope "/", AgentDbWeb do
    pipe_through(:browser)
    live("/admin", AdminLive, :index)
    live("/admin/documents/:id/edit", DocumentEditorLive, :edit)
  end

  scope "/", AgentDbWeb.Controllers do
    pipe_through(:api)

    post("/mcp", McpController, :handle)
  end

  scope "/api/v1", AgentDbWeb.Controllers do
    pipe_through(:api)

    get("/health", HealthController, :show)
    get("/models/status", ModelController, :status)
    post("/search", SearchController, :search)
    get("/search/suggest", SearchController, :suggest)

    resources("/documents", DocumentController, except: [:new, :edit])

    resources "/sessions", SessionController, only: [:create, :show] do
      post("/messages", SessionController, :append_message)
      post("/commit", SessionController, :commit)
    end
  end

  if Mix.env() == :dev do
    scope "/dev", AgentDbWeb do
      pipe_through(:browser)
      forward("/dashboard", Phoenix.LiveDashboard, metrics: true)
    end
  end
end
