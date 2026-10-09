defmodule AgentDbWeb.Admin.SessionsLive do
  @moduledoc """
  The console's sessions page: looking a session up by id.

  Sessions have no store-wide index to list, so the page looks one up by ID. An
  unknown ID reads back as no messages, which is reported as such rather than as
  an empty session.
  """
  use AgentDbWeb.Admin

  alias AgentDb.Observability
  alias AgentDbWeb.AdminComponents

  @admin_page :sessions

  @impl Phoenix.LiveView
  def handle_event("lookup_session", %{"session_id" => id}, socket) do
    {:noreply, lookup_session(socket, String.trim(id || ""))}
  end

  def load(socket) do
    socket
    |> assign_new(:session_id, fn -> "" end)
    |> assign_new(:session_messages, fn -> [] end)
    |> assign_new(:session_notice, fn -> nil end)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header>
        <h1 class="text-2xl font-semibold text-gray-900">Sessions</h1>
      </header>

      <AdminComponents.session_lookup
        session_id={@session_id}
        messages={@session_messages}
        notice={@session_notice}
      />
    </div>
    """
  end

  defp lookup_session(socket, "") do
    assign(socket, session_id: "", session_messages: [], session_notice: "Enter a session ID.")
  end

  defp lookup_session(socket, id) do
    case Context.get_session(id) do
      {:ok, []} ->
        assign(socket,
          session_id: id,
          session_messages: [],
          session_notice: "No session with that ID."
        )

      {:ok, messages} ->
        assign(socket, session_id: id, session_messages: messages, session_notice: nil)

      {:error, reason} ->
        assign(socket,
          session_id: id,
          session_messages: [],
          session_notice: "Could not read session: #{Observability.error_message(reason)}"
        )
    end
  end
end
