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

  alias AgentDbWeb.Context

  @refresh_ms 30_000
  # Bursts (e.g. a bulk import publishing one event per change) reload at most
  # once per window; every event still lands in the feed.
  @coalesce_ms 1_000
  @feed_max 20
  @search_top_k 10

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
          search_notice: "Search failed: #{inspect(reason)}"
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
        assign(socket, session_id: id, session_messages: [], session_notice: "No session with that ID.")

      {:ok, messages} ->
        assign(socket, session_id: id, session_messages: messages, session_notice: nil)

      {:error, reason} ->
        assign(socket,
          session_id: id,
          session_messages: [],
          session_notice: "Could not read session: #{inspect(reason)}"
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
      health: Context.health_check(),
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
      {:error, reason} -> "Could not remove #{uri}: #{inspect(reason)}"
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold text-gray-900">AgentDb</h1>
        <p class="text-sm text-gray-500"><%= @documents.meta.total %> documents</p>
      </header>

      <p :if={@notice} class="rounded bg-blue-50 px-3 py-2 text-sm text-blue-900"><%= @notice %></p>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Recent changes</h2>
        <ul :if={@recent_changes == []} class="px-4 pb-4 text-sm text-gray-500">
          <li>No changes yet</li>
        </ul>
        <ul id="recent-changes" class="divide-y divide-gray-100">
          <li
            :for={change <- @recent_changes}
            class="flex items-center justify-between px-4 py-2 text-sm"
          >
            <span class="font-mono text-gray-900"><%= change.uri %></span>
            <span class="font-mono text-gray-500"><%= change.kind %> &middot; v<%= change.version %></span>
          </li>
        </ul>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Import skills</h2>
        <form id="import-skills" phx-submit="import_skills" class="space-y-4 px-4 pb-4">
          <div>
            <label for="skill-user-id" class="block text-sm text-gray-700">User ID</label>
            <input
              type="text"
              id="skill-user-id"
              name="user_id"
              value={@user_id}
              placeholder="alice"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
            <p class="mt-1 text-sm text-gray-500">
              Skills are stored below <code class="font-mono">viking://user/&lt;user&gt;/skills</code>,
              one subtree per user.
            </p>
          </div>

          <div>
            <label for="skill-folder" class="block text-sm text-gray-700">Skills folder</label>
            <.live_file_input upload={@uploads[:skill_folder]} webkitdirectory />
            <p class="mt-1 text-sm text-gray-500">
              A folder holding one skill, or a collection of skill folders. Each skill needs a SKILL.md.
            </p>
            <ul class="mt-2 space-y-1">
              <li
                :for={entry <- @uploads.skill_folder.entries}
                class="rounded bg-gray-50 px-2 py-1 text-xs text-gray-700"
              >
                <%= entry.client_relative_path || entry.client_name %>
                <span :if={not entry.done?}><%= entry.progress %>%</span>
              </li>
            </ul>
            <p
              :for={reason <- upload_errors(@uploads[:skill_folder])}
              class="mt-1 text-sm text-red-700"
            >
              <%= upload_error_to_string(reason) %>
            </p>
          </div>

          <div>
            <label for="skill-archive" class="block text-sm text-gray-700">Skills archive</label>
            <.live_file_input upload={@uploads[:skill_archive]} />
            <p class="mt-1 text-sm text-gray-500">
              A .tar or .tar.gz holding the same folders, optionally under one wrapper directory.
            </p>
            <ul class="mt-2 space-y-1">
              <li
                :for={entry <- @uploads.skill_archive.entries}
                class="rounded bg-gray-50 px-2 py-1 text-xs text-gray-700"
              >
                <%= entry.client_name %>
                <span :if={not entry.done?}><%= entry.progress %>%</span>
              </li>
            </ul>
            <p
              :for={reason <- upload_errors(@uploads[:skill_archive])}
              class="mt-1 text-sm text-red-700"
            >
              <%= upload_error_to_string(reason) %>
            </p>
          </div>

          <p class="text-sm text-gray-500">
            UTF-8 text only, at most <%= @limits.max_entries %> files and
            <%= @limits.max_bytes %> bytes. A skill whose name is already stored is replaced whole.
          </p>

          <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">
            Import skills
          </button>
        </form>

        <ul :if={@results != []} class="divide-y divide-gray-100 border-t border-gray-200">
          <li :for={result <- @results} class="flex items-center justify-between px-4 py-2 text-sm">
            <span class="font-mono text-gray-900"><%= result.name %></span>
            <span :if={result.status == :failed} class="text-red-700">
              <%= Context.skill_import_error(result.reason) %>
            </span>
            <span :if={result.status != :failed} class="text-gray-500">
              <%= result.status %> &middot; <%= result.files %> files
            </span>
          </li>
        </ul>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Search documents</h2>
        <form id="doc-search" phx-submit="search" class="space-y-4 px-4 pb-4">
          <div class="flex flex-wrap items-end gap-4">
            <div>
              <label for="search-term" class="block text-sm text-gray-700">Search term</label>
              <input
                type="text"
                id="search-term"
                name="term"
                value={@search_term}
                placeholder="keyword"
                class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
              />
            </div>
            <div>
              <label for="search-scope" class="block text-sm text-gray-700">Scope (optional URI)</label>
              <input
                type="text"
                id="search-scope"
                name="scope"
                value={@search_scope}
                placeholder="viking://resources/project"
                class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
              />
            </div>
            <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">
              Search
            </button>
          </div>
          <p :if={@search_notice} class="text-sm text-gray-500"><%= @search_notice %></p>
        </form>

        <ul :if={@search_results != []} class="divide-y divide-gray-100 border-t border-gray-200">
          <li
            :for={result <- @search_results}
            class="flex items-center justify-between px-4 py-2 text-sm"
          >
            <a
              class="font-mono text-blue-700 hover:underline"
              href={"/admin/documents/#{URI.encode_www_form(result.uri)}/edit"}
            >
              <%= result.uri %>
            </a>
            <span :if={Map.has_key?(result, :score)} class="text-gray-500">
              <%= Float.round(Map.get(result, :score) / 1, 3) %>
            </span>
          </li>
        </ul>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Models</h2>
        <p class="px-4 pb-2 text-sm text-gray-500">
          Provider: <%= Map.get(@models, :provider, "unknown") %> &middot; Backend: <%= Map.get(
            @models,
            :backend,
            "unknown"
          ) %> &middot; Memory (BEAM total): <%= format_memory(Map.get(@models, :memory_bytes)) %>
        </p>
        <dl class="grid grid-cols-2 gap-4 px-4 pb-4 text-sm">
          <div :for={{role, entry} <- models_summary(@models)}>
            <dt class="text-gray-500"><%= role %></dt>
            <dd class="font-mono text-gray-900">
              <%= model_state(entry) %>
            </dd>
            <dd class="font-mono text-sm text-gray-700">
              <%= model_identity(role, entry) %>
            </dd>
            <dd class="font-mono text-sm text-gray-700">
              Last inference: <%= format_latency(Map.get(entry, :last_latency_ms)) %>
            </dd>
          </div>
        </dl>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Queue</h2>
        <dl class="grid grid-cols-4 gap-4 px-4 pb-4 text-sm">
          <div :for={status <- [:pending, :running, :done, :failed]}>
            <dt class="text-gray-500"><%= status %></dt>
            <dd class="text-lg font-semibold text-gray-900"><%= Map.get(@jobs, status, 0) %></dd>
          </div>
        </dl>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Health</h2>
        <dl class="grid grid-cols-3 gap-4 px-4 pb-4 text-sm">
          <div>
            <dt class="text-gray-500">status</dt>
            <dd class="font-mono text-gray-900"><%= Map.get(@health, :status, "unknown") %></dd>
          </div>
          <div :for={{check, ok} <- Map.get(@health, :checks, %{})}>
            <dt class="text-gray-500"><%= check %></dt>
            <dd class="font-mono text-gray-900"><%= if ok, do: "ok", else: "down" %></dd>
          </div>
        </dl>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Session lookup</h2>
        <form id="session-lookup" phx-submit="lookup_session" class="space-y-4 px-4 pb-4">
          <div class="flex flex-wrap items-end gap-4">
            <div>
              <label for="session-id" class="block text-sm text-gray-700">Session ID</label>
              <input
                type="text"
                id="session-id"
                name="session_id"
                value={@session_id}
                placeholder="session id"
                class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
              />
            </div>
            <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">
              Look up session
            </button>
          </div>
          <p :if={@session_notice} class="text-sm text-gray-500"><%= @session_notice %></p>
        </form>

        <ul :if={@session_messages != []} class="divide-y divide-gray-100 border-t border-gray-200">
          <li :for={msg <- @session_messages} class="px-4 py-2 text-sm">
            <span class="font-mono text-gray-500"><%= msg.seq %> [<%= msg.role %>]</span>
            <span class="text-gray-900"><%= msg.content %></span>
          </li>
        </ul>
      </section>

      <section class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Documents</h2>
        <ul :if={@documents.names == []} class="px-4 pb-4 text-sm text-gray-500">
          <li>No documents</li>
        </ul>
        <ul class="divide-y divide-gray-100">
          <li :for={name <- @documents.names} class="flex items-center justify-between px-4 py-2">
            <a class="font-mono text-sm text-blue-700 hover:underline" href={"/admin/documents/#{URI.encode_www_form(name)}/edit"}>
              <%= name %>
            </a>
            <button phx-click="delete" phx-value-uri={name} class="text-sm text-red-600 hover:underline">
              Remove
            </button>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp upload_error_to_string(:too_many_files),
    do: "That is more files than one import accepts."

  defp upload_error_to_string(:too_large),
    do: "One of those files is larger than one import accepts."

  defp upload_error_to_string(reason), do: inspect(reason)

  defp models_summary(models) do
    for role <- [:embedding, :llm], Map.has_key?(models, role) do
      {role, Map.get(models, role, %{})}
    end
  end

  # What the store reports for a role, in words. A role mid-download reads as
  # loading rather than simply unloaded, so an operator can tell a store that
  # is still starting from one that has no model.
  defp model_state(entry) when is_map(entry) do
    state = Map.get(entry, :state, "unknown")
    loaded = Map.get(entry, :loaded, false)

    cond do
      state == :loading -> "loading (load in progress)"
      state == "loading" -> "loading (load in progress)"
      loaded -> "#{state} · loaded"
      true -> "#{state} · not loaded"
    end
  end

  # The configured model behind a role: embedding reports dimensionality and
  # the summarizer its configured parameter size. Latency and memory come from
  # the status itself; a backend that does not report them reads as
  # "not reported" rather than as a zero.
  defp model_identity(:embedding, entry) when is_map(entry) do
    "model #{Map.get(entry, :model, "unknown")} · dim #{Map.get(entry, :dim, "unknown")}"
  end

  defp model_identity(:llm, entry) when is_map(entry) do
    "model #{Map.get(entry, :model, "unknown")} · params #{Map.get(entry, :params, "unknown")}"
  end

  defp model_identity(_role, entry) when is_map(entry) do
    "model #{Map.get(entry, :model, "unknown")}"
  end

  defp format_latency(ms) when is_integer(ms) and ms >= 0, do: "#{ms} ms"
  defp format_latency(_), do: "not reported yet"

  defp format_memory(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_memory(_), do: "not reported"
end
