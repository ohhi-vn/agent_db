defmodule AgentDbWeb.Admin.MemoriesLive do
  @moduledoc """
  The console's memories page: what the store holds as memory.

  Counts per type and per status, the memories waiting for review, and actions
  to promote, reject, or forget one. Every value is read-only except the
  operator's explicit actions.
  """
  use AgentDbWeb.Admin

  alias AgentDb.Observability
  alias AgentDbWeb.AdminComponents

  @admin_page :memories

  def load(socket) do
    socket
    |> assign_new(:notice, fn -> nil end)
    |> assign(stats: load_stats(), candidates: load_candidates())
  end

  @impl Phoenix.LiveView
  def handle_event("promote", %{"uri" => uri}, socket) do
    case Context.promote_memory(uri) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           notice: "Promoted #{uri}",
           candidates: load_candidates(),
           stats: load_stats()
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, notice: "Could not promote: #{Observability.error_message(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("reject", %{"uri" => uri}, socket) do
    case Context.reject_memory_candidate(uri) do
      :ok ->
        {:noreply,
         assign(socket,
           notice: "Rejected #{uri}",
           candidates: load_candidates(),
           stats: load_stats()
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, notice: "Could not reject: #{Observability.error_message(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("forget", %{"uri" => uri}, socket) do
    case Context.forget_memory(uri) do
      :ok ->
        {:noreply,
         assign(socket,
           notice: "Forgot #{uri}",
           candidates: load_candidates(),
           stats: load_stats()
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, notice: "Could not forget: #{Observability.error_message(reason)}")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header>
        <h1 class="text-2xl font-semibold text-gray-900">Memories</h1>
      </header>

      <p :if={@notice} class="rounded bg-blue-50 px-3 py-2 text-sm text-blue-900"><%= @notice %></p>

      <AdminComponents.memory_stats stats={@stats} />
      <AdminComponents.memory_candidates candidates={@candidates} />
    </div>
    """
  end

  defp load_stats do
    case Context.memory_statistics() do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  defp load_candidates do
    case Context.pending_memory_candidates([]) do
      {:ok, memories} -> memories
      {:error, _} -> []
    end
  end
end
