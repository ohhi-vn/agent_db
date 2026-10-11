defmodule AgentDbWeb.AdminComponents do
  @moduledoc """
  The console's sections, as function components.

  One LiveView still owns `/admin` -- its lifecycle, its subscriptions, and the
  data it loads. What lives here is only presentation, so that a section is
  something you can read, and a new one is something you add, without editing a
  template that has grown past the point where its sections can be found in it.

  Every component here is given its data. None of them calls the store: an
  operator sees what the facade reported, which is what a program gets, and a
  second path into the store would make the console a way to see things the
  rest of the system cannot.
  """

  use Phoenix.Component

  alias AgentDbWeb.Context

  # -- flash --

  attr(:flash, :map, required: true)

  @doc """
  The feedback a page set for the operator, one entry per kind.

  A LiveView sets feedback with `put_flash`, but it only reaches the operator if
  a layout renders it. Every console page shares this shell, so rendering it here
  is what makes the outcome of an action visible without leaving the page. The
  host is always present -- an empty one measures nothing -- so the live region
  exists before any message arrives.
  """
  def flash_group(assigns) do
    ~H"""
    <div id="flash" aria-live="polite">
      <div
        :for={{kind, message} <- @flash}
        class={["mx-6 mt-6 rounded border px-3 py-2 text-sm font-medium shadow-sm", flash_class(kind)]}
        role={flash_role(kind)}
      >
        <%= message %>
      </div>
    </div>
    """
  end

  defp flash_role("error"), do: "alert"
  defp flash_role(_), do: "status"

  defp flash_class("error"), do: "border-red-300 bg-red-50 text-red-800"
  defp flash_class("info"), do: "border-green-300 bg-green-50 text-green-800"
  defp flash_class(_other), do: "border-gray-300 bg-gray-50 text-gray-800"

  # -- navigation --

  attr(:active, :atom, required: true)

  @doc "The console's sidebar navigation, marking the page currently shown."
  def sidebar(assigns) do
    ~H"""
    <nav class="flex flex-col gap-1 px-2" aria-label="Console">
      <.nav_link page={:overview} label="Overview" href="/admin" active={@active} />
      <.nav_link page={:documents} label="Documents" href="/admin/documents" active={@active} />
      <.nav_link page={:storage} label="Storage" href="/admin/storage" active={@active} />
      <.nav_link page={:skills} label="Skills" href="/admin/skills" active={@active} />
      <.nav_link page={:sessions} label="Sessions" href="/admin/sessions" active={@active} />
    </nav>
    """
  end

  attr(:page, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:href, :string, required: true)
  attr(:active, :atom, required: true)

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      data-active={@active == @page}
      class={["block rounded px-3 py-2 text-sm", nav_class(@active == @page)]}
    >
      <%= @label %>
    </.link>
    """
  end

  defp nav_class(true),
    do: "bg-indigo-50 font-medium text-indigo-700 ring-1 ring-inset ring-indigo-100"

  defp nav_class(false), do: "text-gray-700 hover:bg-gray-100"

  # -- recent changes --

  attr(:changes, :list, required: true)

  @doc "The recent-change feed: URI, kind, and version only."
  def recent_changes(assigns) do
    ~H"""
    <section class="admin-card admin-card-sky rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Recent changes</h2>
      <ul :if={@changes == []} class="px-4 pb-4 text-sm text-gray-500">
        <li>No changes yet</li>
      </ul>
      <ul id="recent-changes" class="divide-y divide-gray-100">
        <li :for={change <- @changes} class="flex items-center justify-between px-4 py-2 text-sm">
          <span class="font-mono text-gray-900"><%= change.uri %></span>
          <span class="font-mono text-gray-500"><%= change.kind %> &middot; v<%= change.version %></span>
        </li>
      </ul>
    </section>
    """
  end

  # -- skill import --

  attr(:uploads, :map, required: true)
  attr(:user_id, :string, default: "")
  attr(:limits, :map, required: true)
  attr(:results, :list, default: [])

  @doc "Where an operator imports Agent Skills from."
  def import_skills(assigns) do
    ~H"""
    <section class="admin-card admin-card-violet rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Import skills</h2>
      <form id="import-skills" phx-change="validate" phx-submit="import_skills" class="space-y-4 px-4 pb-4">
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
          <p :for={reason <- upload_errors(@uploads[:skill_folder])} class="mt-1 text-sm text-red-700">
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
          <p :for={reason <- upload_errors(@uploads[:skill_archive])} class="mt-1 text-sm text-red-700">
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
    """
  end

  # -- search --

  attr(:term, :string, default: "")
  attr(:scope, :string, default: "")
  attr(:results, :list, default: [])
  attr(:notice, :string, default: nil)

  @doc "Document search over the store, linking each hit to the editor."
  def search(assigns) do
    ~H"""
    <section class="admin-card admin-card-cyan rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Search documents</h2>
      <form id="doc-search" phx-submit="search" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="search-term" class="block text-sm text-gray-700">Search term</label>
            <input
              type="text"
              id="search-term"
              name="term"
              value={@term}
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
              value={@scope}
              placeholder="viking://resources/project"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
          </div>
          <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Search</button>
        </div>
        <p :if={@notice} class="text-sm text-gray-500"><%= @notice %></p>
      </form>

      <ul :if={@results != []} class="divide-y divide-gray-100 border-t border-gray-200">
        <li :for={result <- @results} class="flex items-center justify-between px-4 py-2 text-sm">
          <a class="font-mono text-blue-700 hover:underline" href={"/admin/documents/#{URI.encode_www_form(result.uri)}/edit"}>
            <%= result.uri %>
          </a>
          <span :if={Map.has_key?(result, :score)} class="text-gray-500">
            <%= Float.round(Map.get(result, :score) / 1, 3) %>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  # -- models --

  attr(:models, :map, required: true)

  @doc "Model state per role, with load duration and live inference count."
  def models(assigns) do
    ~H"""
    <section class="admin-card admin-card-indigo rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Models</h2>
      <p class="px-4 pb-2 text-sm text-gray-500">
        Provider: <%= Map.get(@models, :provider, "unknown") %> &middot; Backend: <%= Map.get(
          @models,
          :backend,
          "unknown"
        ) %> &middot; Memory (BEAM total): <%= format_bytes(Map.get(@models, :memory_bytes)) %> &middot;
        In flight: <%= Map.get(@models, :in_flight, 0) %> &middot;
        Health: <%= health_word(@models) %>
      </p>
      <dl class="grid grid-cols-2 gap-4 px-4 pb-4 text-sm">
        <div :for={{role, entry} <- models_summary(@models)}>
          <dt class="text-gray-500"><%= role %></dt>
          <dd class="font-mono text-gray-900"><%= model_state(entry) %></dd>
          <dd class="font-mono text-sm text-gray-700"><%= model_identity(role, entry) %></dd>
          <dd class="font-mono text-sm text-gray-700">
            Last load: <%= format_ms(Map.get(entry, :last_load_ms)) %> &middot;
            Last inference: <%= format_ms(Map.get(entry, :last_latency_ms)) %>
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  # The roles the store serves. Kept here with the components that render them
  # so a third role is one line rather than a change in three places.
  defp models_summary(models) do
    for role <- [:embedding, :llm],
        Map.has_key?(models, role),
        do: {role, Map.get(models, role, %{})}
  end

  # What the store reports for a role, in words. A role mid-download reads as
  # loading rather than simply unloaded, and a remote provider that cannot be
  # reached reads as unreachable rather than as ready.
  defp model_state(entry) when is_map(entry) do
    state = Map.get(entry, :state, "unknown")
    loaded = Map.get(entry, :loaded, false)

    cond do
      state in [:loading, "loading"] -> "loading (load in progress)"
      loaded -> "#{state} · loaded"
      true -> "#{state} · not loaded"
    end
  end

  # The configured model behind a role: embedding reports dimensionality and
  # the summarizer its configured parameter size. A figure that is not reported
  # reads as "not reported" rather than as a zero.
  defp model_identity(:embedding, entry) when is_map(entry) do
    "model #{Map.get(entry, :model, "unknown")} · dim #{Map.get(entry, :dim, "unknown")}"
  end

  defp model_identity(:llm, entry) when is_map(entry) do
    "model #{Map.get(entry, :model, "unknown")} · params #{Map.get(entry, :params, "unknown")}"
  end

  defp model_identity(_role, entry) when is_map(entry) do
    "model #{Map.get(entry, :model, "unknown")}"
  end

  defp health_word(models) do
    case Map.get(models, :health) do
      nil -> "local"
      :ok -> "reachable"
      :unauthorized -> "unauthorized"
      other -> to_string(other)
    end
  end

  # -- queue --

  attr(:jobs, :map, required: true)
  attr(:detail, :map, required: true)

  @doc "Background work: what is outstanding, how far behind, and what failed."
  def queue(assigns) do
    ~H"""
    <section class="admin-card admin-card-amber rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Queue</h2>
      <dl class="grid grid-cols-5 gap-4 px-4 pb-2 text-sm">
        <div :for={status <- [:pending, :running, :done, :failed]}>
          <dt class="text-gray-500"><%= status %></dt>
          <dd class="text-lg font-semibold text-gray-900"><%= Map.get(@jobs, status, 0) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">oldest pending</dt>
          <dd class="text-lg font-semibold text-gray-900"><%= format_ms(Map.get(@detail, :oldest_pending_ms)) %></dd>
        </div>
      </dl>

      <ul :if={Map.get(@detail, :failed, []) == []} class="px-4 pb-4 text-sm text-gray-500">
        <li>No failed jobs</li>
      </ul>
      <ul id="failed-jobs" :if={Map.get(@detail, :failed, []) != []} class="divide-y divide-gray-100 border-t border-gray-200">
        <li :for={job <- @detail.failed} class="px-4 py-2 text-sm">
          <span class="font-mono text-gray-900"><%= job.kind %></span>
          <span class="font-mono text-gray-500"><%= job.uri %></span>
          <span class="text-red-700"><%= job.last_error || "no reason recorded" %></span>
          <span class="text-gray-500">
            attempts <%= job.attempts %>/<%= job.max_attempts %>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  # -- health --

  attr(:health, :map, required: true)

  @doc "The store's own health checks, per check rather than as one verdict."
  def health(assigns) do
    ~H"""
    <section class="admin-card admin-card-emerald rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Health</h2>
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
    """
  end

  # -- sessions --

  attr(:session_id, :string, default: "")
  attr(:messages, :list, default: [])
  attr(:notice, :string, default: nil)

  @doc "Looking a session up by id; the store keeps no index to list them by."
  def session_lookup(assigns) do
    ~H"""
    <section class="admin-card admin-card-rose rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Session lookup</h2>
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
          <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Look up session</button>
        </div>
        <p :if={@notice} class="text-sm text-gray-500"><%= @notice %></p>
      </form>

      <ul :if={@messages != []} class="divide-y divide-gray-100 border-t border-gray-200">
        <li :for={message <- @messages} class="px-4 py-2 text-sm">
          <span class="font-mono text-gray-500"><%= message.seq %> [<%= message.role %>]</span>
          <span class="text-gray-900"><%= message.content %></span>
        </li>
      </ul>
    </section>
    """
  end

  # -- documents --

  attr(:documents, :map, required: true)
  attr(:root, :string, required: true)

  @doc """
  The store's documents, one bounded page at a time.

  `root` is the URI the page was listed from, so each entry becomes the URI it
  actually names. Everything that acts on a row needs that full URI: the editor
  link and the removal button both hand it to the store, and a bare name is not
  something the store can resolve -- acting on one reports `invalid_uri` for an
  entry the operator can plainly see.
  """
  def documents(assigns) do
    ~H"""
    <section class="admin-card admin-card-sky rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Documents</h2>
      <ul :if={@documents.names == []} class="px-4 pb-4 text-sm text-gray-500">
        <li>No documents</li>
      </ul>
      <ul class="divide-y divide-gray-100">
        <li :for={name <- @documents.names} class="flex items-center justify-between px-4 py-2">
          <a
            class="font-mono text-sm text-blue-700 hover:underline"
            href={"/admin/documents/#{URI.encode_www_form(child_uri(@root, name))}/edit"}
          >
            <%= name %>
          </a>
          <button
            phx-click="delete"
            phx-value-uri={child_uri(@root, name)}
            class="text-sm text-red-600 hover:underline"
          >
            Remove
          </button>
        </li>
      </ul>

      <div :if={@documents.meta.total_pages > 1} class="flex items-center gap-4 border-t border-gray-200 px-4 py-3 text-sm">
        <span class="text-gray-500">
          Page <%= @documents.meta.page %> of <%= @documents.meta.total_pages %>
          (<%= @documents.meta.total %> entries at this level)
        </span>
        <a
          :if={@documents.meta.page > 1}
          class="text-blue-700 hover:underline"
          href={page_href(@documents.meta, -1)}
        >
          Previous
        </a>
        <a
          :if={@documents.meta.page < @documents.meta.total_pages}
          class="text-blue-700 hover:underline"
          href={page_href(@documents.meta, 1)}
        >
          Next
        </a>
      </div>
    </section>
    """
  end

  attr(:listing, :map, required: true)
  attr(:substring, :string, default: "")
  attr(:group, :string, default: "")
  attr(:show_disabled, :boolean, default: false)

  @doc """
  Recursive show-all document listing with status and group per row.

  Rows carry full URIs, so toggle and group actions address what the store
  resolves. Bulk actions apply to the current filtered set.
  """
  def documents_all(assigns) do
    ~H"""
    <section class="admin-card admin-card-sky rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">All documents</h2>
      <form id="all-doc-filter" phx-submit="filter_all" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="all-substring" class="block text-sm text-gray-700">Filter (substring)</label>
            <input
              type="text"
              id="all-substring"
              name="substring"
              value={@substring}
              placeholder="auth"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
          </div>
          <div>
            <label for="all-group" class="block text-sm text-gray-700">Group</label>
            <input
              type="text"
              id="all-group"
              name="group"
              value={@group}
              placeholder="resources"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
          </div>
          <div class="flex items-center gap-2">
            <input
              type="checkbox"
              id="all-show-disabled"
              name="show_disabled"
              value="true"
              checked={@show_disabled}
              class="rounded border border-gray-300"
            />
            <label for="all-show-disabled" class="text-sm text-gray-700">Include disabled</label>
          </div>
          <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Apply</button>
        </div>
      </form>

      <div class="flex flex-wrap items-center gap-4 border-t border-gray-200 px-4 py-3 text-sm">
        <span class="text-gray-500">
          <%= @listing.meta.total %> documents (page <%= @listing.meta.page %> of <%= @listing.meta.total_pages %>)
        </span>
        <button phx-click="bulk_disable_all" class="text-sm text-red-600 hover:underline">
          Disable filtered
        </button>
        <button phx-click="bulk_enable_all" class="text-sm text-blue-700 hover:underline">
          Enable filtered
        </button>
      </div>

      <form id="bulk-group-all" phx-submit="bulk_set_group_all" class="flex flex-wrap items-end gap-4 px-4 pb-4">
        <div>
          <label for="bulk-group-tag" class="block text-sm text-gray-700">Set group for filtered</label>
          <input
            type="text"
            id="bulk-group-tag"
            name="group_tag"
            placeholder="release-1 (empty clears)"
            class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
          />
        </div>
        <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Apply group</button>
      </form>

      <ul :if={@listing.data == []} class="px-4 pb-4 text-sm text-gray-500">
        <li>No documents match</li>
      </ul>
      <ul class="divide-y divide-gray-100">
        <li :for={row <- @listing.data} class="px-4 py-2">
          <div class="flex items-center justify-between">
            <a
              class="font-mono text-sm text-blue-700 hover:underline"
              href={"/admin/documents/#{URI.encode_www_form(row.uri)}/edit"}
            >
              <%= row.uri %>
            </a>
            <span class="text-sm text-gray-500">
              <%= if row.enabled, do: "enabled", else: "disabled" %> &middot; <%= group_label(row.group_tag) %>
            </span>
          </div>
          <div class="mt-1 flex items-center gap-4">
            <button
              phx-click="toggle_enabled"
              phx-value-uri={row.uri}
              phx-value-enabled={to_string(row.enabled)}
              class="text-sm text-blue-700 hover:underline"
            >
              <%= if row.enabled, do: "Disable", else: "Enable" %>
            </button>
            <form phx-submit="set_group" class="flex items-center gap-2">
              <input type="hidden" name="uri" value={row.uri} />
              <input
                type="text"
                name="group_tag"
                value={row.group_tag}
                placeholder="group (empty clears)"
                class="w-40 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
              />
              <button type="submit" class="text-sm text-blue-700 hover:underline">Set group</button>
            </form>
          </div>
        </li>
      </ul>

      <div :if={@listing.meta.total_pages > 1} class="flex items-center gap-4 border-t border-gray-200 px-4 py-3 text-sm">
        <span class="text-gray-500">
          Page <%= @listing.meta.page %> of <%= @listing.meta.total_pages %>
        </span>
        <button
          :if={@listing.meta.page > 1}
          phx-click="all_page"
          phx-value-page={@listing.meta.page - 1}
          class="text-blue-700 hover:underline"
        >
          Previous
        </button>
        <button
          :if={@listing.meta.page < @listing.meta.total_pages}
          phx-click="all_page"
          phx-value-page={@listing.meta.page + 1}
          class="text-blue-700 hover:underline"
        >
          Next
        </button>
      </div>
    </section>
    """
  end

  attr(:inventory, :map, required: true)
  attr(:substring, :string, default: "")
  attr(:owner, :string, default: "")
  attr(:group, :string, default: "")
  attr(:show_disabled, :boolean, default: false)
  attr(:llm_uri, :string, default: nil)
  attr(:llm_view, :map, default: nil)

  @doc """
  Installed-skill inventory with status and group per row, alongside import.

  A row's LLM view toggle expands the files under that skill root with the
  layers the store answers for each file.
  """
  def skills_inventory(assigns) do
    ~H"""
    <section class="admin-card admin-card-violet rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Installed skills</h2>
      <form id="skill-filter" phx-submit="filter_skills" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="skill-filter-text" class="block text-sm text-gray-700">Search skills</label>
            <input
              type="text"
              id="skill-filter-text"
              name="substring"
              value={@substring}
              placeholder="review"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
          </div>
          <div>
            <label for="skill-filter-owner" class="block text-sm text-gray-700">Owner</label>
            <input
              type="text"
              id="skill-filter-owner"
              name="owner"
              value={@owner}
              placeholder="alice"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
          </div>
          <div>
            <label for="skill-filter-group" class="block text-sm text-gray-700">Group</label>
            <input
              type="text"
              id="skill-filter-group"
              name="group"
              value={@group}
              placeholder="reviewers"
              class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
            />
          </div>
          <div class="flex items-center gap-2">
            <input
              type="checkbox"
              id="skill-show-disabled"
              name="show_disabled"
              value="true"
              checked={@show_disabled}
              class="rounded border border-gray-300"
            />
            <label for="skill-show-disabled" class="text-sm text-gray-700">Include disabled</label>
          </div>
          <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Apply</button>
        </div>
      </form>

      <div class="flex flex-wrap items-center gap-4 border-t border-gray-200 px-4 py-3 text-sm">
        <span class="text-gray-500">
          <%= @inventory.meta.total %> skills (page <%= @inventory.meta.page %> of <%= @inventory.meta.total_pages %>)
        </span>
        <button phx-click="bulk_disable_skills" class="text-sm text-red-600 hover:underline">
          Disable filtered
        </button>
        <button phx-click="bulk_enable_skills" class="text-sm text-blue-700 hover:underline">
          Enable filtered
        </button>
      </div>

      <form id="bulk-group-skills" phx-submit="bulk_set_group_skills" class="flex flex-wrap items-end gap-4 px-4 pb-4">
        <div>
          <label for="bulk-skill-group-tag" class="block text-sm text-gray-700">Set group for filtered</label>
          <input
            type="text"
            id="bulk-skill-group-tag"
            name="group_tag"
            placeholder="reviewers (empty clears)"
            class="mt-1 w-64 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
          />
        </div>
        <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Apply group</button>
      </form>

      <ul :if={@inventory.data == []} class="px-4 pb-4 text-sm text-gray-500">
        <li>No skills installed</li>
      </ul>
      <ul class="divide-y divide-gray-100">
        <li :for={row <- @inventory.data} class="px-4 py-2">
          <div class="flex items-center justify-between">
            <span class="font-mono text-sm text-gray-900"><%= row.name %></span>
            <span class="text-sm text-gray-500">
              <%= row.owner %> &middot; <%= row.files %> files &middot; <%= if row.enabled, do: "enabled", else: "disabled" %> &middot; <%= group_label(row.group_tag) %>
            </span>
          </div>
          <p class="font-mono text-sm text-gray-500"><%= row.uri %></p>
          <div class="mt-1 flex items-center gap-4">
            <button
              phx-click="toggle_skill"
              phx-value-uri={row.uri}
              phx-value-enabled={to_string(row.enabled)}
              class="text-sm text-blue-700 hover:underline"
            >
              <%= if row.enabled, do: "Disable", else: "Enable" %>
            </button>
            <button
              phx-click="toggle_llm_view"
              phx-value-uri={row.uri}
              class="text-sm text-blue-700 hover:underline"
            >
              <%= if @llm_uri == row.uri, do: "Hide LLM view", else: "LLM view" %>
            </button>
            <form phx-submit="set_skill_group" class="flex items-center gap-2">
              <input type="hidden" name="uri" value={row.uri} />
              <input
                type="text"
                name="group_tag"
                value={row.group_tag}
                placeholder="group (empty clears)"
                class="w-40 rounded border border-gray-300 px-2 py-1 font-mono text-sm"
              />
              <button type="submit" class="text-sm text-blue-700 hover:underline">Set group</button>
            </form>
          </div>
          <div :if={@llm_uri == row.uri} class="mt-2 space-y-3 border-t border-gray-100 pt-2">
            <p :if={is_nil(@llm_view) or @llm_view[:error]} class="text-sm text-gray-500">
              Could not load files for this skill.
            </p>
            <p
              :if={!is_nil(@llm_view) and !@llm_view[:error] and @llm_view.files == []}
              class="text-sm text-gray-500"
            >
              No files stored under this skill.
            </p>
            <.llm_layers :for={file <- llm_files(@llm_view)} title={file.uri} layers={file.layers} />
            <div
              :if={!is_nil(@llm_view) and !@llm_view[:error] and @llm_view.meta.total_pages > 1}
              class="flex items-center gap-4 text-sm"
            >
              <span class="text-gray-500">
                Page <%= @llm_view.meta.page %> of <%= @llm_view.meta.total_pages %>
              </span>
              <button
                :if={@llm_view.meta.page > 1}
                phx-click="llm_files_page"
                phx-value-page={@llm_view.meta.page - 1}
                class="text-blue-700 hover:underline"
              >
                Previous
              </button>
              <button
                :if={@llm_view.meta.page < @llm_view.meta.total_pages}
                phx-click="llm_files_page"
                phx-value-page={@llm_view.meta.page + 1}
                class="text-blue-700 hover:underline"
              >
                Next
              </button>
            </div>
          </div>
        </li>
      </ul>

      <div :if={@inventory.meta.total_pages > 1} class="flex items-center gap-4 border-t border-gray-200 px-4 py-3 text-sm">
        <span class="text-gray-500">
          Page <%= @inventory.meta.page %> of <%= @inventory.meta.total_pages %>
        </span>
        <button
          :if={@inventory.meta.page > 1}
          phx-click="skills_page"
          phx-value-page={@inventory.meta.page - 1}
          class="text-blue-700 hover:underline"
        >
          Previous
        </button>
        <button
          :if={@inventory.meta.page < @inventory.meta.total_pages}
          phx-click="skills_page"
          phx-value-page={@inventory.meta.page + 1}
          class="text-blue-700 hover:underline"
        >
          Next
        </button>
      </div>
    </section>
    """
  end

  defp group_label(""), do: "ungrouped"
  defp group_label(tag), do: tag

  defp llm_files(nil), do: []
  defp llm_files(%{files: files}), do: files
  defp llm_files(_other), do: []

  # -- llm layers --

  attr(:layers, :map, required: true)
  attr(:title, :string, default: "How the LLM sees this document")

  @doc """
  The LLM-facing layers of one document: L0 abstract, L1 overview, L2 content.

  Given the map `Context.get_layers/1` returns. Presentation only: it never
  reads the store, so what the operator sees is what a program gets. A layer
  longer than the excerpt bound renders its excerpt with the full text one
  expand away, so a large document stays usable.
  """
  def llm_layers(assigns) do
    ~H"""
    <section class="admin-card admin-card-indigo rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900"><%= @title %></h2>
      <div class="space-y-4 px-4 pb-4">
        <.llm_layer label="Abstract (L0)" layer={@layers.l0} />
        <.llm_layer label="Overview (L1)" layer={@layers.l1} />
        <.llm_layer label="Full content (L2)" layer={@layers.l2} />
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:layer, :map, required: true)

  defp llm_layer(assigns) do
    ~H"""
    <div>
      <div class="flex items-baseline gap-2 text-sm">
        <h3 class="font-medium text-gray-900"><%= @label %></h3>
        <span class={["rounded px-2 py-0.5 font-mono text-xs", layer_badge_class(@layer.source)]}>
          <%= @layer.source %>
        </span>
        <span class="font-mono text-xs text-gray-500"><%= @layer.chars %> chars</span>
      </div>
      <p :if={@layer.source == :unavailable} class="mt-1 text-sm text-gray-500">Not available.</p>
      <pre
        :if={@layer.source != :unavailable and @layer.chars <= 500}
        class="mt-1 whitespace-pre-wrap rounded bg-gray-50 px-3 py-2 font-mono text-sm text-gray-900"
      ><%= @layer.text %></pre>
      <div :if={@layer.source != :unavailable and @layer.chars > 500} class="mt-1">
        <pre class="whitespace-pre-wrap rounded bg-gray-50 px-3 py-2 font-mono text-sm text-gray-900"><%= String.slice(@layer.text, 0, 500) %>…</pre>
        <details class="mt-1">
          <summary class="cursor-pointer text-sm text-blue-700 hover:underline">
            Show full <%= @label %> (<%= @layer.chars %> chars)
          </summary>
          <pre class="mt-1 max-h-96 overflow-auto whitespace-pre-wrap rounded bg-gray-50 px-3 py-2 font-mono text-sm text-gray-900"><%= @layer.text %></pre>
        </details>
      </div>
    </div>
    """
  end

  defp layer_badge_class(:stored), do: "bg-green-50 text-green-800"
  defp layer_badge_class(:fallback), do: "bg-amber-50 text-amber-700"
  defp layer_badge_class(_other), do: "bg-gray-50 text-gray-500"

  # -- storage, cache, indexes, runtime --

  attr(:storage, :map, required: true)
  attr(:cache, :map, required: true)

  @doc "What the store holds, and how much of that is the cache rather than content."
  def footprint(assigns) do
    ~H"""
    <section class="admin-card admin-card-emerald rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Storage</h2>
      <dl class="grid grid-cols-4 gap-4 px-4 pb-2 text-sm">
        <div>
          <dt class="text-gray-500">documents</dt>
          <dd class="text-lg font-semibold text-gray-900"><%= Map.get(@storage, :documents, 0) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">directories</dt>
          <dd class="text-lg font-semibold text-gray-900"><%= Map.get(@storage, :directories, 0) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">database</dt>
          <dd class="font-mono text-gray-900"><%= format_bytes(Map.get(@storage, :db_bytes)) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">write-ahead log</dt>
          <dd class="font-mono text-gray-900"><%= format_bytes(Map.get(@storage, :wal_bytes)) %></dd>
        </div>
      </dl>

      <dl class="grid grid-cols-3 gap-4 px-4 pb-4 text-sm">
        <div :for={{subtree, count} <- Enum.sort(Map.get(@storage, :by_top_subtree, %{}))}>
          <dt class="text-gray-500"><%= subtree_label(subtree) %></dt>
          <dd class="font-mono text-gray-900"><%= count %> docs</dd>
        </div>
      </dl>

      <p class="px-4 pb-2 text-sm text-gray-500">Cache</p>
      <dl class="grid grid-cols-3 gap-4 px-4 pb-4 text-sm">
        <div>
          <dt class="text-gray-500">nodes</dt>
          <dd class="font-mono text-gray-900">
            <%= entry_text(Map.get(@cache, :node_cache, %{})) %>
          </dd>
        </div>
        <div>
          <dt class="text-gray-500">listings</dt>
          <dd class="font-mono text-gray-900">
            <%= entry_text(Map.get(@cache, :dir_cache, %{})) %>
          </dd>
        </div>
        <div>
          <dt class="text-gray-500">total</dt>
          <dd class="font-mono text-gray-900"><%= format_bytes(Map.get(@cache, :total_bytes)) %></dd>
        </div>
      </dl>
    </section>
    """
  end

  defp entry_text(entry) when is_map(entry) do
    "#{Map.get(entry, :entries, 0)} entries · #{format_bytes(Map.get(entry, :bytes))}"
  end

  defp entry_text(_), do: "not reported"

  # A document filed at the tree root has no subtree segment, and an empty
  # label would read as a rendering fault rather than as what it is.
  defp subtree_label(""), do: "(root)"
  defp subtree_label(name), do: name

  defp page_href(meta, step), do: "/admin?page=#{meta.page + step}"

  # A root already ending in a separator -- the tree root's `viking://` is the
  # scheme's own -- takes the name directly; anything else needs one between.
  defp child_uri(root, name) when is_binary(name) do
    if String.ends_with?(root, "/") do
      root <> name
    else
      root <> "/" <> name
    end
  end

  defp process_count(runtime) do
    runtime
    |> Map.get(:process_counts, %{})
    |> Map.get(:total, 0)
  end

  attr(:coverage, :map, required: true)

  @doc """
  How much of the store each index covers.

  An index that cannot be queried says so: "not available" and "nothing indexed
  yet" are different states, and telling them apart is the whole point of the
  section.
  """
  def indexes(assigns) do
    ~H"""
    <section class="admin-card admin-card-teal rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Indexes</h2>
      <dl class="grid grid-cols-4 gap-4 px-4 pb-4 text-sm">
        <div>
          <dt class="text-gray-500">vector</dt>
          <dd class="font-mono text-gray-900"><%= vector_line(@coverage) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">code</dt>
          <dd class="font-mono text-gray-900">
            <%= Map.get(@coverage, :code_documents, 0) %> docs
          </dd>
        </div>
        <div>
          <dt class="text-gray-500">hex docs</dt>
          <dd class="font-mono text-gray-900">
            <%= Map.get(@coverage, :hex_documents, 0) %> docs
          </dd>
        </div>
        <div>
          <dt class="text-gray-500">locked packages</dt>
          <dd class="font-mono text-gray-900">
            <%= Map.get(@coverage, :hex_packages, 0) %> of <%= Map.get(@coverage, :hex_locked, 0) %> covered
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  defp vector_line(coverage) do
    if Map.get(coverage, :available, false) do
      "#{Map.get(coverage, :vectors, 0)} of #{Map.get(coverage, :documents, 0)} docs"
    else
      "index not available"
    end
  end

  attr(:runtime, :map, required: true)
  attr(:errors, :list, default: [])

  @doc "How long the node has been up, what it is running, and what has failed."
  def runtime(assigns) do
    ~H"""
    <section class="admin-card admin-card-orange rounded-lg border border-gray-200 bg-white shadow-sm">
      <h2 class="admin-card-title px-4 py-3 font-medium text-gray-900">Runtime</h2>
      <p :if={@runtime[:error]} class="px-4 pb-2 text-sm text-gray-500">
        A runtime snapshot could not be taken.
      </p>
      <dl :if={!@runtime[:error]} class="grid grid-cols-5 gap-4 px-4 pb-2 text-sm">
        <div>
          <dt class="text-gray-500">uptime</dt>
          <dd class="font-mono text-gray-900"><%= format_ms(Map.get(@runtime, :uptime_ms)) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">processes</dt>
          <dd class="font-mono text-gray-900">
            <%= process_count(@runtime) %>
          </dd>
        </div>
        <div>
          <dt class="text-gray-500">supervisors</dt>
          <dd class="font-mono text-gray-900"><%= length(Map.get(@runtime, :supervisors, [])) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">ETS tables</dt>
          <dd class="font-mono text-gray-900"><%= length(Map.get(@runtime, :ets, [])) %></dd>
        </div>
        <div>
          <dt class="text-gray-500">BEAM memory</dt>
          <dd class="font-mono text-gray-900">
            <%= format_bytes(Map.get(Map.get(@runtime, :memory, %{}), :total)) %>
          </dd>
        </div>
      </dl>

      <p class="px-4 pb-2 text-sm text-gray-500">Recent failures</p>
      <ul :if={@errors == []} class="px-4 pb-4 text-sm text-gray-500">
        <li>No recorded failures</li>
      </ul>
      <ul id="recent-errors" :if={@errors != []} class="divide-y divide-gray-100 border-t border-gray-200">
        <li :for={entry <- @errors} class="flex items-center justify-between px-4 py-2 text-sm">
          <span class="font-mono text-gray-900"><%= entry.operation || entry.family %></span>
          <span class="text-red-700"><%= entry.reason %></span>
        </li>
      </ul>
    </section>
    """
  end

  # -- shared formatting --

  defp format_ms(nil), do: "not reported"
  defp format_ms(ms) when is_integer(ms) and ms >= 0, do: "#{ms} ms"
  defp format_ms(_), do: "not reported"

  defp format_bytes(nil), do: "not reported"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "not reported"

  defp upload_error_to_string(:too_many_files), do: "That is more files than one import accepts."

  defp upload_error_to_string(:too_large),
    do: "One of those files is larger than one import accepts."

  defp upload_error_to_string(reason), do: Context.skill_import_error(reason)
end
