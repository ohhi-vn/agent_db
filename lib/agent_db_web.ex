defmodule AgentDbWeb do
  @moduledoc """
  The main web module for AgentDb.
  """

defmacro __using__(which) when is_atom(which) do
    quote do
      unquote(case which do
        :controller -> controller()
        :live_view -> live_view()
        :router -> router()
        :endpoint -> endpoint()
        :html_helpers -> html_helpers()
        :view -> view()
      end)
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        namespace: AgentDbWeb,
        json_library: Jason

      import Plug.Conn
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {AgentDbWeb.Layouts, :live}

      import Phoenix.HTML
      import Phoenix.LiveView.Helpers
      import Phoenix.Component
      import Phoenix.Param
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/agent_db_web/templates",
        namespace: AgentDbWeb

      import Phoenix.Controller, only: [get_csrf_token: 0, get_flash: 2, view_module: 1]
      import Phoenix.Component
    end
  end

  def html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.LiveView.Helpers
      import Phoenix.Component
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
    end
  end

  def endpoint do
    quote do
      use Phoenix.Endpoint, otp_app: :agent_db

      import Plug.Conn
    end
  end
end