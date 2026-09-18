defmodule AgentDbWeb.AdminLive do
  use Phoenix.LiveView,
    layout: {AgentDbWeb.Layouts, :live}

  import Phoenix.HTML
  import Phoenix.LiveView.Helpers
  import Phoenix.Component
  import Phoenix.Param
  alias AgentDbWeb.Context

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AgentDb.PubSub, "documents")
      Phoenix.PubSub.subscribe(AgentDb.PubSub, "sessions")
      Phoenix.PubSub.subscribe(AgentDb.PubSub, "jobs")
    end
    
    {:ok, assign(socket, 
      documents: load_documents(), 
      active_tab: "documents",
      sessions: [],
      model_status: load_model_status(),
      job_stats: load_job_stats()
    )}
  end

  def handle_params(%{"tab" => tab}, _uri, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab) |> push_patch(to: "/admin?tab=#{tab}")}
  end

  def handle_info({:doc_change, _uri}, socket) do
    {:noreply, assign(socket, documents: load_documents())}
  end

  def handle_info({:session_change, _id}, socket) do
    {:noreply, assign(socket, sessions: load_sessions())}
  end

  def handle_info({:job_change, _id}, socket) do
    {:noreply, assign(socket, job_stats: load_job_stats())}
  end

  defp load_documents do
    with {:ok, %{data: docs}} <- Context.list_documents([]) do
      docs
    else
      {:error, _} -> []
    end
  end

  defp load_sessions do
    with {:ok, sessions} <- Context.list_sessions([]) do
      sessions
    else
      {:error, _reason} -> []
    end
  end

  defp load_model_status do
    Context.model_status()
  end

  defp load_job_stats do
    with {:ok, stats} <- AgentDb.JobQueue.stats() do
      stats
    else
      {:error, _reason} -> %{}
    end
  end

  defp render_documents_tab(assigns, documents) do
    ~H"""
    <div class="bg-white rounded-lg shadow-sm border border-gray-200">
      <div class="p-4 border-b border-gray-200 flex justify-between items-center">
        <h2 class="text-lg font-medium text-gray-900">Documents (<%= length(documents) %>)</h2>
        <a href="/admin/documents/new/edit" class="text-sm text-blue-600 hover:text-blue-800">New Document</a>
      </div>
      <div class="divide-y divide-gray-200">
        <%= if documents == [] do %>
          <div class="p-8 text-center text-gray-500">No documents found</div>
        <% else %>
          <%= for doc <- documents do %>
            <div class="p-4 hover:bg-gray-50 flex justify-between items-center">
              <div>
                <code class="text-sm font-mono text-gray-700"><%= doc %></code>
                <div class="flex items-center space-x-2 mt-1">
                  <a href={"/admin/documents/#{URI.encode_www_form(doc)}/edit"} class="text-sm text-blue-600 hover:text-blue-800">Edit</a>
                  <span class="text-gray-300">|</span>
                  <button 
                    phx-click="delete_document" 
                    phx-value-uri={doc}
                    class="text-sm text-red-600 hover:text-red-800">Delete</button>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_sessions_tab(assigns, sessions) do
    ~H"""
    <div class="bg-white rounded-lg shadow-sm border border-gray-200">
      <div class="p-4 border-b border-gray-200">
        <h2 class="text-lg font-medium text-gray-900">Sessions (<%= length(sessions) %>)</h2>
      </div>
      <div class="divide-y divide-gray-200">
        <%= if sessions == [] do %>
          <div class="p-8 text-center text-gray-500">No sessions found</div>
        <% else %>
          <%= for session <- sessions do %>
            <div class="p-4 hover:bg-gray-50">
              <code class="text-sm font-mono text-gray-700"><%= session.id %></code>
              <div class="text-sm text-gray-500 mt-1"><%= length(session.messages) %> messages</div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_models_tab(assigns, model_status) do
    ~H"""
    <div class="bg-white rounded-lg shadow-sm border border-gray-200">
      <div class="p-4 border-b border-gray-200">
        <h2 class="text-lg font-medium text-gray-900">Model Status</h2>
      </div>
      <div class="p-4 space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="p-4 bg-gray-50 rounded-lg">
            <h3 class="font-medium text-gray-900 mb-2">Embedding Model</h3>
            <%= render_model_info(assigns, model_status.embedding) %>
          </div>
          <div class="p-4 bg-gray-50 rounded-lg">
            <h3 class="font-medium text-gray-900 mb-2">LLM Model</h3>
            <%= render_model_info(assigns, model_status.llm) %>
          </div>
        </div>
        <div class="p-4 bg-gray-50 rounded-lg">
          <h3 class="font-medium text-gray-900 mb-2">Queue</h3>
          <pre class="text-sm"><%= Jason.encode!(model_status.queue) %></pre>
        </div>
      </div>
    </div>
    """
  end

  defp render_jobs_tab(assigns, job_stats) do
    ~H"""
    <div class="bg-white rounded-lg shadow-sm border border-gray-200">
      <div class="p-4 border-b border-gray-200">
        <h2 class="text-lg font-medium text-gray-900">Job Queue</h2>
      </div>
      <div class="p-4 space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
          <div class="p-4 bg-blue-50 rounded-lg">
            <dt class="text-sm text-gray-500">Pending</dt>
            <dd class="text-2xl font-bold text-blue-700"><%= Map.get(job_stats, :pending, 0) %></dd>
          </div>
          <div class="p-4 bg-yellow-50 rounded-lg">
            <dt class="text-sm text-gray-500">Running</dt>
            <dd class="text-2xl font-bold text-yellow-700"><%= Map.get(job_stats, :running, 0) %></dd>
          </div>
          <div class="p-4 bg-green-50 rounded-lg">
            <dt class="text-sm text-gray-500">Completed</dt>
            <dd class="text-2xl font-bold text-green-700"><%= Map.get(job_stats, :completed, 0) %></dd>
          </div>
          <div class="p-4 bg-red-50 rounded-lg">
            <dt class="text-sm text-gray-500">Failed</dt>
            <dd class="text-2xl font-bold text-red-700"><%= Map.get(job_stats, :failed, 0) %></dd>
          </div>
        </div>
        <div class="p-4 bg-gray-50 rounded-lg">
          <pre class="text-sm"><%= Jason.encode!(job_stats) %></pre>
        </div>
      </div>
    </div>
    """
  end

  defp render_unknown_tab(assigns) do
    ~H"""
    <div class="p-8 text-center text-gray-500">Unknown tab</div>
    """
  end

  defp render_model_info(assigns, model) do
    ~H"""
    <dl class="space-y-1 text-sm">
      <div class="flex justify-between">
        <dt class="text-gray-500">Loaded</dt>
        <dd class="font-medium"><%= if model.loaded do %>✓ Yes<% else %>✗ No<% end %></dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-gray-500">Dimensions</dt>
        <dd class="font-medium"><%= model.dim || "N/A" %></dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-gray-500">Parameters</dt>
        <dd class="font-medium"><%= model.params || "N/A" %></dd>
      </div>
      <div class="flex justify-between">
        <dt class="text-gray-500">Last Latency</dt>
        <dd class="font-medium"><%= model.last_latency_ms || "N/A" %>ms</dd>
      </div>
    </dl>
    """
  end
end