defmodule AgentDbWeb.AdminLive do
  @moduledoc """
  The operations console.

  A view of what the store holds and what it is doing, and the place an operator
  imports Agent Skills from. It answers through the same facade every other client
  uses, so what an operator does here is what a program gets -- there is no second,
  more forgiving path into the store for the console's benefit.

  The console subscribes to context changes on connect, so writes, removals,
  skill replacements and session commits appear without waiting for the periodic
  refresh. The refresh remains as a fallback for missed events. The recent-change
  feed carries only URI, kind and version -- never document content.
  """
  use Phoenix.LiveView, layout: {AgentDbWeb.Layouts, :live}

  import Phoenix.LiveView
  import Phoenix.Component

  alias AgentDb.Observability
  alias AgentDbWeb.AdminComponents
  alias AgentDbWeb.Context

  @refresh_ms 30_000
  # Bursts (e.g. a bulk import publishing one event per change) reload at most
  # once per window; every event still lands in the feed.
  @coalesce_ms 1_000
  @feed_max 20
  @search_top_k 10
  # The tree root the console browses; the listing is its direct children.
  @tree_root "viking://"
  @error_max 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # The root is an ancestor of every change, so one subscription sees all
      # writes, removals, replacements and commits. Process-scoped: it ends
      # with this LiveView and is re-established on reconnect.
      _ = AgentDb.subscribe("viking://")
      :timer.send_interval(@refresh_ms, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(
       page: 1,
       user_id: "",
       results: [],
       limits: AgentDb.skill_import_limits(),
       search_term: "",
       search_scope: "",
       search_results: [],
       search_notice: nil,
       recent_changes: [],
       session_id: "",
       session_messages: [],
       session_notice: nil,
       tree_root: @tree_root,
       last_reload_ms: 0,
       reload_pending: false
     )
     |> allow_skill_uploads()
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"page" => page}, _uri, socket) do
    {:noreply, socket |> assign(page: page) |> load()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, reload(socket)}

  def handle_info(:refresh_coalesced, socket), do: {:noreply, reload(socket)}

  def handle_info({:context_changed, uri, kind, version}, socket) do
    feed = [%{uri: uri, kind: kind, version: version} | socket.assigns.recent_changes]
    socket = assign(socket, recent_changes: Enum.take(feed, @feed_max))

    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_reload_ms] || 0

    cond do
      socket.assigns[:reload_pending] ->
        {:noreply, socket}

      now - last < @coalesce_ms ->
        Process.send_after(self(), :refresh_coalesced, @coalesce_ms)
        {:noreply, assign(socket, reload_pending: true)}

      true ->
        {:noreply, reload(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("delete", %{"uri" => uri}, socket) do
    {:noreply, socket |> assign(notice: delete(uri)) |> load()}
  end

  def handle_event("search", %{"term" => term, "scope" => scope}, socket) do
    {:noreply, search(socket, String.trim(term || ""), String.trim(scope || ""))}
  end

  def handle_event("lookup_session", %{"session_id" => id}, socket) do
    {:noreply, lookup_session(socket, String.trim(id || ""))}
  end

  @impl Phoenix.LiveView
  def handle_event("import_skills", params, socket) do
    case read_source(socket) do
      :empty ->
        {:noreply, assign(socket, results: [], notice: "Choose a skills folder or an archive.")}

      {:ok, source} ->
        {:noreply, socket |> import_skills(params["user_id"] || "", source) |> load()}
    end
  end

  # A search leaves the tree listing in place: a failure reports in words and
  # the current page stays, so a refused search never blanks the console.
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

  # Sessions have no store-wide index to list, so the console looks one up by
  # ID. An unknown ID reads back as no messages, which is reported as such
  # rather than as an empty session.
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

  # The browser's caps are the bounds the importer itself accepts, so a bundle
  # that would be refused is refused before it is uploaded rather than after.
  defp allow_skill_uploads(socket) do
    limits = socket.assigns.limits

    # Any kind of file: a skill is whatever its author put in it, and the
    # importer is what decides whether a file is one it can store. An archive is
    # recognised by what it holds rather than by what it is called, so its
    # extension is not filtered either -- a `.tgz`, a `.tar.gz` and a tar that
    # was renamed are the same to the importer, and it reports one it cannot read.
    socket
    |> allow_upload(:skill_folder,
      accept: :any,
      max_entries: limits.max_entries,
      max_file_size: limits.max_bytes
    )
    |> allow_upload(:skill_archive,
      accept: :any,
      max_entries: 1,
      max_file_size: limits.max_bytes
    )
  end

  # Which of the two forms the operator filled in. An archive is one file and a
  # folder is many, so the choice is read off the uploads rather than asked for.
  defp read_source(socket) do
    if uploaded?(socket, :skill_archive) do
      {:ok, {:archive, archive(socket)}}
    else
      folder(socket)
    end
  end

  defp folder(socket) do
    if uploaded?(socket, :skill_folder) do
      {:ok, {:uploads, consume_uploaded_entries(socket, :skill_folder, &folder_file/2)}}
    else
      :empty
    end
  end

  defp archive(socket) do
    [bytes] =
      consume_uploaded_entries(socket, :skill_archive, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    bytes
  end

  # A folder selection arrives as one entry per file, each carrying the path it
  # had inside the folder the operator chose -- which is what says whether the
  # source is one skill or a collection of them.
  defp folder_file(%{path: path}, entry) do
    name = entry.client_relative_path || entry.client_name
    {:ok, %{path: name, content: File.read!(path)}}
  end

  defp uploaded?(socket, name) do
    case socket.assigns.uploads[name] do
      %{entries: [_ | _] = entries} -> Enum.all?(entries, & &1.done?)
      _none -> false
    end
  end

  defp import_skills(socket, user_id, source) do
    case Context.import_skills(user_id, source) do
      {:ok, %{skills: skills}} ->
        assign(socket, user_id: user_id, results: skills, notice: summary(skills))

      {:error, reason} ->
        assign(socket,
          results: [],
          notice: "Import refused: #{Context.skill_import_error(reason)}"
        )
    end
  end

  defp summary(skills) do
    [
      count(skills, :imported, "imported"),
      count(skills, :replaced, "replaced"),
      count(skills, :failed, "failed")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp count(skills, status, label) do
    case Enum.count(skills, &(&1.status == status)) do
      0 -> nil
      n -> "#{n} #{label}"
    end
  end

  # A reload refreshes the live sections and stamps the time, clearing any
  # pending coalesced reload. Search results, session lookup and the feed are
  # the operator's working state and survive a reload untouched.
  defp reload(socket) do
    socket
    |> load()
    |> assign(last_reload_ms: System.monotonic_time(:millisecond), reload_pending: false)
  end

  defp load(socket) do
    assign(socket,
      documents: documents(socket.assigns.page),
      models: Context.model_status(),
      jobs: Context.job_stats(),
      queue_detail: Context.queue_detail(@error_max),
      health: Context.health_check(),
      storage: Context.storage_stats(),
      cache: Context.cache_stats(),
      coverage: Context.index_coverage(),
      runtime: Context.runtime_snapshot(),
      recent_errors: Context.recent_errors(@error_max),
      notice: socket.assigns[:notice]
    )
  end

  # The console lists the tree root, one page at a time: a store can hold more
  # documents than fit in a table, and a console that tried to show all of them
  # would be unusable on exactly the stores it is most needed for.
  @page_size 50

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

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold text-gray-900">AgentDb</h1>
        <p class="text-sm text-gray-500"><%= @storage.documents %> documents</p>
      </header>

      <p :if={@notice} class="rounded bg-blue-50 px-3 py-2 text-sm text-blue-900"><%= @notice %></p>

      <AdminComponents.recent_changes changes={@recent_changes} />
      <AdminComponents.footprint storage={@storage} cache={@cache} />
      <AdminComponents.indexes coverage={@coverage} />
      <AdminComponents.models models={@models} />
      <AdminComponents.queue jobs={@jobs} detail={@queue_detail} />
      <AdminComponents.runtime runtime={@runtime} errors={@recent_errors} />
      <AdminComponents.health health={@health} />
      <AdminComponents.search
        term={@search_term}
        scope={@search_scope}
        results={@search_results}
        notice={@search_notice}
      />
      <AdminComponents.import_skills
        uploads={@uploads}
        user_id={@user_id}
        limits={@limits}
        results={@results}
      />
      <AdminComponents.session_lookup
        session_id={@session_id}
        messages={@session_messages}
        notice={@session_notice}
      />
      <AdminComponents.documents documents={@documents} root={@tree_root} />
    </div>
    """
  end
end
