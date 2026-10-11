defmodule AgentDbWeb.Admin.DocumentsLive do
  @moduledoc """
  The console's documents page: what the store holds, one page at a time, and
  how to find a document in it.

  The listing is the tree root's direct children, bounded to a page so a large
  store stays usable; the count beside it is the true number of documents the
  store holds. Search runs over store content and links each hit to the editor.
  A refused search reports in words and leaves the listing in place.

  The show-all section lists every document URI recursively, one bounded page
  at a time, with a substring/group filter, disabled opt-in, and per-row plus
  bulk enable/disable and group assignment.
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

  def handle_event("filter_all", params, socket) do
    socket =
      socket
      |> assign(
        all_substring: String.trim(params["substring"] || ""),
        all_group: String.trim(params["group"] || ""),
        all_show_disabled: params["show_disabled"] in ["true", "on", "1"],
        all_page: 1
      )
      |> load()

    {:noreply, socket}
  end

  def handle_event("all_page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(all_page: page) |> load()}
  end

  def handle_event("toggle_enabled", %{"uri" => uri} = params, socket) do
    {:noreply, socket |> assign(notice: toggle(uri, params["enabled"])) |> load()}
  end

  def handle_event("bulk_disable_all", _params, socket) do
    {:noreply, socket |> assign(notice: bulk_set_enabled(socket, false)) |> load()}
  end

  def handle_event("bulk_enable_all", _params, socket) do
    {:noreply, socket |> assign(notice: bulk_set_enabled(socket, true)) |> load()}
  end

  def handle_event("set_group", %{"uri" => uri, "group_tag" => tag}, socket) do
    {:noreply, socket |> assign(notice: set_group(uri, String.trim(tag || ""))) |> load()}
  end

  def handle_event("bulk_set_group_all", %{"group_tag" => tag}, socket) do
    {:noreply, socket |> assign(notice: bulk_set_group(socket, String.trim(tag || ""))) |> load()}
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
    |> assign_new(:all_page, fn -> 1 end)
    |> assign_new(:all_substring, fn -> "" end)
    |> assign_new(:all_group, fn -> "" end)
    |> assign_new(:all_show_disabled, fn -> false end)
    |> assign(all_listing: all_listing(socket))
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
      <AdminComponents.documents_all
        listing={@all_listing}
        substring={@all_substring}
        group={@all_group}
        show_disabled={@all_show_disabled}
      />
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

  defp all_listing(socket) do
    assigns = socket.assigns

    opts = %{
      "scope" => @tree_root,
      "page" => assigns[:all_page] || 1,
      "per_page" => @page_size,
      "substring" => assigns[:all_substring] || "",
      "group" => assigns[:all_group] || "",
      "include_disabled" => assigns[:all_show_disabled] || false
    }

    case Context.list_all_documents(opts) do
      {:ok, %{data: rows, meta: meta}} ->
        %{data: rows, meta: meta}

      {:error, _reason} ->
        %{data: [], meta: %{page: 1, per_page: @page_size, total: 0, total_pages: 1}}
    end
  end

  defp current_page_uris(socket) do
    case socket.assigns[:all_listing] do
      %{data: rows} -> Enum.map(rows, & &1.uri)
      _ -> []
    end
  end

  defp toggle(uri, "false") do
    case Context.set_enabled(uri, true) do
      :ok -> "Enabled #{uri}"
      {:error, reason} -> "Could not enable #{uri}: #{Observability.error_message(reason)}"
    end
  end

  defp toggle(uri, _currently_enabled) do
    case Context.set_enabled(uri, false) do
      :ok -> "Disabled #{uri}"
      {:error, reason} -> "Could not disable #{uri}: #{Observability.error_message(reason)}"
    end
  end

  defp bulk_set_enabled(socket, enabled) do
    uris = current_page_uris(socket)
    verb = if enabled, do: "Enabled", else: "Disabled"

    case Context.bulk_set_enabled(uris, enabled) do
      {:ok, %{updated: updated, failed: 0}} ->
        "#{verb} #{updated} document(s)"

      {:ok, %{updated: updated, failed: failed}} ->
        "#{verb} #{updated} document(s), #{failed} failed"

      {:error, reason} ->
        "Bulk action failed: #{Observability.error_message(reason)}"
    end
  end

  defp set_group(uri, tag) do
    case Context.set_group(uri, tag) do
      :ok -> "Set group for #{uri} to #{group_word(tag)}"
      {:error, reason} -> "Could not set group for #{uri}: #{Observability.error_message(reason)}"
    end
  end

  defp bulk_set_group(socket, tag) do
    uris = current_page_uris(socket)

    case Context.bulk_set_group(uris, tag) do
      {:ok, %{updated: updated, failed: 0}} ->
        "Set group for #{updated} document(s) to #{group_word(tag)}"

      {:ok, %{updated: updated, failed: failed}} ->
        "Set group for #{updated} document(s) to #{group_word(tag)}, #{failed} failed"

      {:error, reason} ->
        "Bulk action failed: #{Observability.error_message(reason)}"
    end
  end

  defp group_word(""), do: "ungrouped"
  defp group_word(tag), do: tag

  defp delete(uri) do
    case Context.delete_document(uri) do
      :ok -> "Removed #{uri}"
      {:error, reason} -> "Could not remove #{uri}: #{Observability.error_message(reason)}"
    end
  end
end
