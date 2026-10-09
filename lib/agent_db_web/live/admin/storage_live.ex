defmodule AgentDbWeb.Admin.StorageLive do
  @moduledoc """
  The console's storage page: what the store holds and how much of it is cache
  rather than content.

  Storage footprint, the disposable read caches, and index coverage. Every value
  is read-only, and an index that cannot be queried says so rather than reading
  as empty.
  """
  use AgentDbWeb.Admin

  alias AgentDbWeb.AdminComponents

  @admin_page :storage

  def load(socket) do
    assign(socket,
      storage: Context.storage_stats(),
      cache: Context.cache_stats(),
      coverage: Context.index_coverage()
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header>
        <h1 class="text-2xl font-semibold text-gray-900">Storage</h1>
      </header>

      <AdminComponents.footprint storage={@storage} cache={@cache} />
      <AdminComponents.indexes coverage={@coverage} />
    </div>
    """
  end
end
