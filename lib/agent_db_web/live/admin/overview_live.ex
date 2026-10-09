defmodule AgentDbWeb.Admin.OverviewLive do
  @moduledoc """
  The console's overview: what the store is doing right now.

  Health, models, the queue, runtime liveness, and the recent-change feed. It is
  the page the console lands on, and the only page that renders the feed.
  """
  use AgentDbWeb.Admin

  alias AgentDbWeb.AdminComponents

  @admin_page :overview
  @error_max 20

  def load(socket) do
    assign(socket,
      models: Context.model_status(),
      jobs: Context.job_stats(),
      queue_detail: Context.queue_detail(@error_max),
      health: Context.health_check(),
      runtime: Context.runtime_snapshot(),
      recent_errors: Context.recent_errors(@error_max)
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header>
        <h1 class="text-2xl font-semibold text-gray-900">Overview</h1>
      </header>

      <AdminComponents.recent_changes changes={@recent_changes} />
      <AdminComponents.models models={@models} />
      <AdminComponents.queue jobs={@jobs} detail={@queue_detail} />
      <AdminComponents.runtime runtime={@runtime} errors={@recent_errors} />
      <AdminComponents.health health={@health} />
    </div>
    """
  end
end
