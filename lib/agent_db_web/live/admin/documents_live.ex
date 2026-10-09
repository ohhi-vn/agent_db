defmodule AgentDbWeb.Admin.DocumentsLive do
  @moduledoc """
  The console's documents page: what the store holds, one page at a time, and
  how to find a document in it.

  The listing is the tree root's direct children, bounded to a page so a large
  store stays usable; the count beside it is the true number of documents the
  store holds. Search runs over store content and links each hit to the editor.
  A refused search reports in words and leaves the listing in place.
  """
  use AgentDbWeb.Admin

  alias AgentDb.Observability
  alias AgentDbWeb.AdminComponents

  @admin_page :documents
  @page_size 50
  @search_top_k 10
  # The tree root the page browses; the listing is its direct children.
  @tree_root "viking://"

  @impl Phoenix.LiveView
  def handle_params(%{"page" => page}, _uri, socket) do
    {:noreply, socket |> assign(page: page) |> load()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_event("delete", %{"uri" => uri}, socket) do
    {:noreply, socket |> assign(notice: delete(uri)) |> load()}
  end

  def handle_event("search", %{"term" => term, "scope" => scope}, socket) do
    {:noreply, search(socket, String.trim(term || ""), String.trim(scope || ""))}
  end

  def load(socket) do
    page = socket.assigns[:page] || 1

    socket
    |> assign(
      page: page,
      documents: documents(page),
      storage: Context.storage_stats(),
      tree_root: @tree_root
    )
    |> assign_new(:search_term, fn -> "" end)
    |> assign_new(:search_scope, fn -> "" end)
    |> assign_new(:search_results, fn -> [] end)
    |> assign_new(:search_notice, fn -> nil end)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold text-gray-900">Documents</h1>
        <p class="text-sm text-gray-500"><%= @storage.documents %> documents</p>
      </header>

      <p :if={@notice} class="rounded bg-blue-50 px-3 py-2 text-sm text-blue-900"><%= @notice %></p>

      <AdminComponents.search
        term={@search_term}
        scope={@search_scope}
        results={@search_results}
        notice={@search_notice}
      />
      <AdminComponents.documents documents={@documents} root={@tree_root} />
    </div>
    """
  end

  # A search leaves the tree listing in place: a failure reports in words and
  # the current page stays, so a refused search never blanks the page.
  defp search(socket, "", _scope) do
    assign(socket, search_term: "", search_results: [], search_notice: "Enter a search term.")
  end

  defp search(socket, term, scope) do
    opts = %{"mode" => "keyword", "top_k" => @search_top_k, "scope" => scope}

    case Context.search_documents(term, opts) do
      {:ok, results} ->
        assign(socket,
          search_term: term,
          search_scope: scope,
          search_results: results,
          search_notice: "#{length(results)} result(s)"
        )

      {:error, reason} ->
        assign(socket,
          search_term: term,
          search_scope: scope,
          search_results: [],
          search_notice: "Search failed: #{Observability.error_message(reason)}"
        )
    end
  end

  # The page lists the tree root, one page at a time: a store can hold more
  # documents than fit in a table, and a page that tried to show all of them
  # would be unusable on exactly the stores it is most needed for.
  defp documents(page) do
    case Context.list_documents(%{"page" => page, "per_page" => @page_size}) do
      {:ok, %{data: names, meta: meta}} -> %{names: names, meta: meta}
      {:error, _reason} -> %{names: [], meta: %{page: page, total: 0, total_pages: 0}}
    end
  end

  defp delete(uri) do
    case Context.delete_document(uri) do
      :ok -> "Removed #{uri}"
      {:error, reason} -> "Could not remove #{uri}: #{Observability.error_message(reason)}"
    end
  end
end
