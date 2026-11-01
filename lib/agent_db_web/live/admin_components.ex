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
    <div id="flash" aria-live="polite" class="space-y-2">
      <div
        :for={{kind, message} <- @flash}
        class={["alert", alert_class(kind)]}
        role={flash_role(kind)}
      >
        <%= message %>
      </div>
    </div>
    """
  end

  defp flash_role("error"), do: "alert"
  defp flash_role(_), do: "status"

  defp alert_class("error"), do: "alert-error"
  defp alert_class("info"), do: "alert-success"
  defp alert_class(_other), do: "alert-info"

  # -- navigation --

  attr(:active, :atom, required: true)

  @doc "The console's sidebar navigation, marking the page currently shown."
  def sidebar(assigns) do
    ~H"""
    <nav class="menu menu-vertical gap-1 px-2" aria-label="Console">
      <.nav_link page={:overview} label="Overview" href="/admin" active={@active} />
      <.nav_link page={:documents} label="Documents" href="/admin/documents" active={@active} />
      <.nav_link page={:storage} label="Storage" href="/admin/storage" active={@active} />
      <.nav_link page={:skills} label="Skills" href="/admin/skills" active={@active} />
      <.nav_link page={:sessions} label="Sessions" href="/admin/sessions" active={@active} />
      <.nav_link page={:memories} label="Memories" href="/admin/memories" active={@active} />
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

  defp nav_class(true), do: "active bg-primary text-primary-content font-medium"
  defp nav_class(false), do: "text-base-content hover:bg-base-200"

  # -- recent changes --

  attr(:changes, :list, required: true)

  @doc "The recent-change feed: URI, kind, and version only."
  def recent_changes(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-sky-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Recent changes</h2>
      <ul :if={@changes == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No changes yet</li>
      </ul>
      <ul id="recent-changes" class="divide-y divide-base-200">
        <li :for={change <- @changes} class="flex items-center justify-between px-4 py-2 text-sm">
          <span class="font-mono text-base-content"><%= change.uri %></span>
          <span class="font-mono text-base-content/70"><%= change.kind %> &middot; v<%= change.version %></span>
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-violet-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Import skills</h2>
      <form id="import-skills" phx-change="validate" phx-submit="import_skills" class="space-y-4 px-4 pb-4">
        <div>
          <label for="skill-user-id" class="block text-sm text-base-content/80">User ID</label>
          <input
            type="text"
            id="skill-user-id"
            name="user_id"
            value={@user_id}
            placeholder="alice"
            class="input input-bordered input-sm w-64 font-mono"
          />
          <p class="mt-1 text-sm text-base-content/70">
            Skills are stored below <code class="font-mono">viking://user/&lt;user&gt;/skills</code>,
            one subtree per user.
          </p>
        </div>

        <div>
          <label for="skill-folder" class="block text-sm text-base-content/80">Skills folder</label>
          <.live_file_input upload={@uploads[:skill_folder]} webkitdirectory />
          <p class="mt-1 text-sm text-base-content/70">
            A folder holding one skill, or a collection of skill folders. Each skill needs a SKILL.md.
          </p>
          <ul class="mt-2 space-y-1">
            <li
              :for={entry <- @uploads.skill_folder.entries}
              class="badge badge-ghost badge-sm font-mono"
            >
              <%= entry.client_relative_path || entry.client_name %>
              <span :if={not entry.done?}><%= entry.progress %>%</span>
            </li>
          </ul>
          <p :for={reason <- upload_errors(@uploads[:skill_folder])} class="mt-1 text-sm text-error">
            <%= upload_error_to_string(reason) %>
          </p>
        </div>

        <div>
          <label for="skill-archive" class="block text-sm text-base-content/80">Skills archive</label>
          <.live_file_input upload={@uploads[:skill_archive]} />
          <p class="mt-1 text-sm text-base-content/70">
            A .tar or .tar.gz holding the same folders, optionally under one wrapper directory.
          </p>
          <ul class="mt-2 space-y-1">
            <li
              :for={entry <- @uploads.skill_archive.entries}
              class="badge badge-ghost badge-sm font-mono"
            >
              <%= entry.client_name %>
              <span :if={not entry.done?}><%= entry.progress %>%</span>
            </li>
          </ul>
          <p :for={reason <- upload_errors(@uploads[:skill_archive])} class="mt-1 text-sm text-error">
            <%= upload_error_to_string(reason) %>
          </p>
        </div>

        <p class="text-sm text-base-content/70">
          UTF-8 text only, at most <%= @limits.max_entries %> files and
          <%= @limits.max_bytes %> bytes. A skill whose name is already stored is replaced whole.
        </p>

        <button type="submit" class="btn btn-primary btn-sm">
          Import skills
        </button>
      </form>

      <ul :if={@results != []} class="divide-y divide-base-200 border-t border-base-300">
        <li :for={result <- @results} class="flex items-center justify-between px-4 py-2 text-sm">
          <span class="font-mono text-base-content"><%= result.name %></span>
          <span :if={result.status == :failed} class="text-error">
            <%= Context.skill_import_error(result.reason) %>
          </span>
          <span :if={result.status != :failed} class="text-base-content/70">
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-cyan-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Search documents</h2>
      <form id="doc-search" phx-submit="search" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="search-term" class="block text-sm text-base-content/80">Search term</label>
            <input
              type="text"
              id="search-term"
              name="term"
              value={@term}
              placeholder="keyword"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <div>
            <label for="search-scope" class="block text-sm text-base-content/80">Scope (optional URI)</label>
            <input
              type="text"
              id="search-scope"
              name="scope"
              value={@scope}
              placeholder="viking://resources/project"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Search</button>
        </div>
        <p :if={@notice} class="text-sm text-base-content/70"><%= @notice %></p>
      </form>

      <ul :if={@results != []} class="divide-y divide-base-200 border-t border-base-300">
        <li :for={result <- @results} class="flex items-center justify-between px-4 py-2 text-sm">
          <a class="font-mono text-primary hover:underline" href={"/admin/documents/#{URI.encode_www_form(result.uri)}/edit"}>
            <%= result.uri %>
          </a>
          <span :if={Map.has_key?(result, :score)} class="text-base-content/70">
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-indigo-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Models</h2>
      <p class="px-4 pb-2 text-sm text-base-content/70">
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
          <dt class="text-base-content/70"><%= role %></dt>
          <dd class="font-mono text-base-content"><%= model_state(entry) %></dd>
          <dd class="font-mono text-sm text-base-content/80"><%= model_identity(role, entry) %></dd>
          <dd class="font-mono text-sm text-base-content/80">
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-amber-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Queue</h2>
      <p :if={Map.get(@detail, :available, true) == false} class="px-4 pb-2 text-sm text-error">
        Queue unavailable: <%= Map.get(@detail, :reason, :error) %>
      </p>

      <dl :if={Map.get(@detail, :available, true) != false} class="grid grid-cols-5 gap-4 px-4 pb-2 text-sm">
        <div :for={status <- [:pending, :running, :done, :failed]}>
          <dt class="text-base-content/70"><%= status %></dt>
          <dd class="text-lg font-semibold text-base-content"><%= Map.get(@jobs, status, 0) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">oldest pending</dt>
          <dd class="text-lg font-semibold text-base-content"><%= format_ms(Map.get(@detail, :oldest_pending_ms)) %></dd>
        </div>
      </dl>

      <ul :if={Map.get(@detail, :failed, []) == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No failed jobs</li>
      </ul>
      <ul id="failed-jobs" :if={Map.get(@detail, :failed, []) != []} class="divide-y divide-base-200 border-t border-base-300">
        <li :for={job <- @detail.failed} class="px-4 py-2 text-sm">
          <span class="font-mono text-base-content">#<%= job.id %></span>
          <span class="font-mono text-base-content"><%= job.kind %></span>
          <span class="font-mono text-base-content/70"><%= job.uri %></span>
          <span class="text-error"><%= job.last_error || "no reason recorded" %></span>
          <span class="text-base-content/70">
            attempts <%= job.attempts %>/<%= job.max_attempts %>
          </span>
          <span class="text-base-content/70">
            failed at <%= format_ms(job.failed_at) %>
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-emerald-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Health</h2>
      <dl class="grid grid-cols-3 gap-4 px-4 pb-4 text-sm">
        <div>
          <dt class="text-base-content/70">status</dt>
          <dd class="font-mono text-base-content"><%= Map.get(@health, :status, "unknown") %></dd>
        </div>
        <div :for={{check, ok} <- Map.get(@health, :checks, %{})}>
          <dt class="text-base-content/70"><%= check %></dt>
          <dd class={["font-mono", if(ok, do: "text-success", else: "text-error")]}>
            <%= if ok, do: "ok", else: "down" %>
          </dd>
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-rose-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Session lookup</h2>
      <form id="session-lookup" phx-submit="lookup_session" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="session-id" class="block text-sm text-base-content/80">Session ID</label>
            <input
              type="text"
              id="session-id"
              name="session_id"
              value={@session_id}
              placeholder="session id"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Look up session</button>
        </div>
        <p :if={@notice} class="text-sm text-base-content/70"><%= @notice %></p>
      </form>

      <ul :if={@messages != []} class="divide-y divide-base-200 border-t border-base-300">
        <li :for={message <- @messages} class="px-4 py-2 text-sm">
          <span class="font-mono text-base-content/70"><%= message.seq %> [<%= message.role %>]</span>
          <span class="text-base-content"><%= message.content %></span>
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-sky-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Documents</h2>
      <ul :if={@documents.names == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No documents</li>
      </ul>
      <ul class="divide-y divide-base-200">
        <li :for={name <- @documents.names} class="flex items-center justify-between px-4 py-2">
          <a
            class="font-mono text-sm text-primary hover:underline"
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

      <div :if={@documents.meta.total_pages > 1} class="flex items-center gap-4 border-t border-base-300 px-4 py-3 text-sm">
        <span class="text-base-content/70">
          Page <%= @documents.meta.page %> of <%= @documents.meta.total_pages %>
          (<%= @documents.meta.total %> entries at this level)
        </span>
        <a
          :if={@documents.meta.page > 1}
          class="text-primary hover:underline"
          href={page_href(@documents.meta, -1)}
        >
          Previous
        </a>
        <a
          :if={@documents.meta.page < @documents.meta.total_pages}
          class="text-primary hover:underline"
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-sky-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">All documents</h2>
      <form id="all-doc-filter" phx-submit="filter_all" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="all-substring" class="block text-sm text-base-content/80">Filter (substring)</label>
            <input
              type="text"
              id="all-substring"
              name="substring"
              value={@substring}
              placeholder="auth"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <div>
            <label for="all-group" class="block text-sm text-base-content/80">Group</label>
            <input
              type="text"
              id="all-group"
              name="group"
              value={@group}
              placeholder="resources"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <div class="flex items-center gap-2">
            <input
              type="checkbox"
              id="all-show-disabled"
              name="show_disabled"
              value="true"
              checked={@show_disabled}
              class="checkbox checkbox-sm"
            />
            <label for="all-show-disabled" class="text-sm text-base-content/80">Include disabled</label>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Apply</button>
        </div>
      </form>

      <div class="flex flex-wrap items-center gap-4 border-t border-base-300 px-4 py-3 text-sm">
        <span class="text-base-content/70">
          <%= @listing.meta.total %> documents (page <%= @listing.meta.page %> of <%= @listing.meta.total_pages %>)
        </span>
        <button phx-click="bulk_disable_all" class="text-sm text-red-600 hover:underline">
          Disable filtered
        </button>
        <button phx-click="bulk_enable_all" class="text-sm text-primary hover:underline">
          Enable filtered
        </button>
      </div>

      <form id="bulk-group-all" phx-submit="bulk_set_group_all" class="flex flex-wrap items-end gap-4 px-4 pb-4">
        <div>
          <label for="bulk-group-tag" class="block text-sm text-base-content/80">Set group for filtered</label>
          <input
            type="text"
            id="bulk-group-tag"
            name="group_tag"
            placeholder="release-1 (empty clears)"
            class="input input-bordered input-sm w-64 font-mono"
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Apply group</button>
      </form>

      <ul :if={@listing.data == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No documents match</li>
      </ul>
      <ul class="divide-y divide-base-200">
        <li :for={row <- @listing.data} class="px-4 py-2">
          <div class="flex items-center justify-between">
            <a
              class="font-mono text-sm text-primary hover:underline"
              href={"/admin/documents/#{URI.encode_www_form(row.uri)}/edit"}
            >
              <%= row.uri %>
            </a>
            <span class={["text-sm", if(row.enabled, do: "text-success", else: "text-base-content/60")]}>
              <%= if row.enabled, do: "enabled", else: "disabled" %> &middot; <%= group_label(row.group_tag) %>
            </span>
          </div>
          <div class="mt-1 flex items-center gap-4">
            <button
              phx-click="toggle_enabled"
              phx-value-uri={row.uri}
              phx-value-enabled={to_string(row.enabled)}
              class="text-sm text-primary hover:underline"
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
                class="input input-bordered input-sm w-40 font-mono"
              />
              <button type="submit" class="text-sm text-primary hover:underline">Set group</button>
            </form>
          </div>
        </li>
      </ul>

      <div :if={@listing.meta.total_pages > 1} class="flex items-center gap-4 border-t border-base-300 px-4 py-3 text-sm">
        <span class="text-base-content/70">
          Page <%= @listing.meta.page %> of <%= @listing.meta.total_pages %>
        </span>
        <button
          :if={@listing.meta.page > 1}
          phx-click="all_page"
          phx-value-page={@listing.meta.page - 1}
          class="text-primary hover:underline"
        >
          Previous
        </button>
        <button
          :if={@listing.meta.page < @listing.meta.total_pages}
          phx-click="all_page"
          phx-value-page={@listing.meta.page + 1}
          class="text-primary hover:underline"
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-violet-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Installed skills</h2>
      <form id="skill-filter" phx-submit="filter_skills" class="space-y-4 px-4 pb-4">
        <div class="flex flex-wrap items-end gap-4">
          <div>
            <label for="skill-filter-text" class="block text-sm text-base-content/80">Search skills</label>
            <input
              type="text"
              id="skill-filter-text"
              name="substring"
              value={@substring}
              placeholder="review"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <div>
            <label for="skill-filter-owner" class="block text-sm text-base-content/80">Owner</label>
            <input
              type="text"
              id="skill-filter-owner"
              name="owner"
              value={@owner}
              placeholder="alice"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <div>
            <label for="skill-filter-group" class="block text-sm text-base-content/80">Group</label>
            <input
              type="text"
              id="skill-filter-group"
              name="group"
              value={@group}
              placeholder="reviewers"
              class="input input-bordered input-sm w-64 font-mono"
            />
          </div>
          <div class="flex items-center gap-2">
            <input
              type="checkbox"
              id="skill-show-disabled"
              name="show_disabled"
              value="true"
              checked={@show_disabled}
              class="checkbox checkbox-sm"
            />
            <label for="skill-show-disabled" class="text-sm text-base-content/80">Include disabled</label>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Apply</button>
        </div>
      </form>

      <div class="flex flex-wrap items-center gap-4 border-t border-base-300 px-4 py-3 text-sm">
        <span class="text-base-content/70">
          <%= @inventory.meta.total %> skills (page <%= @inventory.meta.page %> of <%= @inventory.meta.total_pages %>)
        </span>
        <button phx-click="bulk_disable_skills" class="text-sm text-red-600 hover:underline">
          Disable filtered
        </button>
        <button phx-click="bulk_enable_skills" class="text-sm text-primary hover:underline">
          Enable filtered
        </button>
      </div>

      <form id="bulk-group-skills" phx-submit="bulk_set_group_skills" class="flex flex-wrap items-end gap-4 px-4 pb-4">
        <div>
          <label for="bulk-skill-group-tag" class="block text-sm text-base-content/80">Set group for filtered</label>
          <input
            type="text"
            id="bulk-skill-group-tag"
            name="group_tag"
            placeholder="reviewers (empty clears)"
            class="input input-bordered input-sm w-64 font-mono"
          />
        </div>
        <button type="submit" class="btn btn-primary btn-sm">Apply group</button>
      </form>

      <ul :if={@inventory.data == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No skills installed</li>
      </ul>
      <ul class="divide-y divide-base-200">
        <li :for={row <- @inventory.data} class="px-4 py-2">
          <div class="flex items-center justify-between">
            <span class="font-mono text-sm text-base-content"><%= row.name %></span>
            <span class="text-sm text-base-content/70">
              <%= row.owner %> &middot; <%= row.files %> files &middot; <%= if row.enabled, do: "enabled", else: "disabled" %> &middot; <%= group_label(row.group_tag) %>
            </span>
          </div>
          <p class="font-mono text-sm text-base-content/70"><%= row.uri %></p>
          <div class="mt-1 flex items-center gap-4">
            <button
              phx-click="toggle_skill"
              phx-value-uri={row.uri}
              phx-value-enabled={to_string(row.enabled)}
              class="text-sm text-primary hover:underline"
            >
              <%= if row.enabled, do: "Disable", else: "Enable" %>
            </button>
            <button
              phx-click="toggle_llm_view"
              phx-value-uri={row.uri}
              class="text-sm text-primary hover:underline"
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
                class="input input-bordered input-sm w-40 font-mono"
              />
              <button type="submit" class="text-sm text-primary hover:underline">Set group</button>
            </form>
          </div>
          <div :if={@llm_uri == row.uri} class="mt-2 space-y-3 border-t border-base-200 pt-2">
            <p :if={is_nil(@llm_view) or @llm_view[:error]} class="text-sm text-base-content/70">
              Could not load files for this skill.
            </p>
            <p
              :if={!is_nil(@llm_view) and !@llm_view[:error] and @llm_view.files == []}
              class="text-sm text-base-content/70"
            >
              No files stored under this skill.
            </p>
            <.llm_layers :for={file <- llm_files(@llm_view)} title={file.uri} layers={file.layers} />
            <div
              :if={!is_nil(@llm_view) and !@llm_view[:error] and @llm_view.meta.total_pages > 1}
              class="flex items-center gap-4 text-sm"
            >
              <span class="text-base-content/70">
                Page <%= @llm_view.meta.page %> of <%= @llm_view.meta.total_pages %>
              </span>
              <button
                :if={@llm_view.meta.page > 1}
                phx-click="llm_files_page"
                phx-value-page={@llm_view.meta.page - 1}
                class="text-primary hover:underline"
              >
                Previous
              </button>
              <button
                :if={@llm_view.meta.page < @llm_view.meta.total_pages}
                phx-click="llm_files_page"
                phx-value-page={@llm_view.meta.page + 1}
                class="text-primary hover:underline"
              >
                Next
              </button>
            </div>
          </div>
        </li>
      </ul>

      <div :if={@inventory.meta.total_pages > 1} class="flex items-center gap-4 border-t border-base-300 px-4 py-3 text-sm">
        <span class="text-base-content/70">
          Page <%= @inventory.meta.page %> of <%= @inventory.meta.total_pages %>
        </span>
        <button
          :if={@inventory.meta.page > 1}
          phx-click="skills_page"
          phx-value-page={@inventory.meta.page - 1}
          class="text-primary hover:underline"
        >
          Previous
        </button>
        <button
          :if={@inventory.meta.page < @inventory.meta.total_pages}
          phx-click="skills_page"
          phx-value-page={@inventory.meta.page + 1}
          class="text-primary hover:underline"
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-indigo-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content"><%= @title %></h2>
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
        <h3 class="font-medium text-base-content"><%= @label %></h3>
        <span class={["badge badge-sm font-mono", layer_badge_class(@layer.source)]}>
          <%= @layer.source %>
        </span>
        <span class="font-mono text-xs text-base-content/70"><%= @layer.chars %> chars</span>
      </div>
      <p :if={@layer.source == :unavailable} class="mt-1 text-sm text-base-content/70">Not available.</p>
      <pre
        :if={@layer.source != :unavailable and @layer.chars <= 500}
        class="mt-1 whitespace-pre-wrap rounded bg-base-200 px-3 py-2 font-mono text-sm text-base-content"
      ><%= @layer.text %></pre>
      <div :if={@layer.source != :unavailable and @layer.chars > 500} class="mt-1">
        <pre class="whitespace-pre-wrap rounded bg-base-200 px-3 py-2 font-mono text-sm text-base-content"><%= String.slice(@layer.text, 0, 500) %>…</pre>
        <details class="mt-1">
          <summary class="cursor-pointer text-sm text-primary hover:underline">
            Show full <%= @label %> (<%= @layer.chars %> chars)
          </summary>
          <pre class="mt-1 max-h-96 overflow-auto whitespace-pre-wrap rounded bg-base-200 px-3 py-2 font-mono text-sm text-base-content"><%= @layer.text %></pre>
        </details>
      </div>
    </div>
    """
  end

  defp layer_badge_class(:stored), do: "badge-success"
  defp layer_badge_class(:fallback), do: "badge-warning"
  defp layer_badge_class(_other), do: "badge-ghost"

  # -- storage, cache, indexes, runtime --

  attr(:storage, :map, required: true)
  attr(:cache, :map, required: true)

  @doc "What the store holds, and how much of that is the cache rather than content."
  def footprint(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-emerald-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Storage</h2>

      <p :if={Map.get(@storage, :available, true) == false} class="px-4 pb-2 text-sm text-error">
        Storage unavailable: <%= Map.get(@storage, :reason, :error) %>
      </p>

      <dl :if={Map.get(@storage, :available, true) != false} class="grid grid-cols-4 gap-4 px-4 pb-2 text-sm">
        <div>
          <dt class="text-base-content/70">documents</dt>
          <dd class="text-lg font-semibold text-base-content"><%= Map.get(@storage, :documents, 0) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">directories</dt>
          <dd class="text-lg font-semibold text-base-content"><%= Map.get(@storage, :directories, 0) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">database</dt>
          <dd class="font-mono text-base-content"><%= format_bytes(Map.get(@storage, :db_bytes)) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">write-ahead log</dt>
          <dd class="font-mono text-base-content"><%= format_bytes(Map.get(@storage, :wal_bytes)) %></dd>
        </div>
      </dl>

      <dl class="grid grid-cols-3 gap-4 px-4 pb-4 text-sm">
        <div :for={{subtree, count} <- Enum.sort(Map.get(@storage, :by_top_subtree, %{}))}>
          <dt class="text-base-content/70"><%= subtree_label(subtree) %></dt>
          <dd class="font-mono text-base-content"><%= count %> docs</dd>
        </div>
      </dl>

      <p class="px-4 pb-2 text-sm text-base-content/70">Cache</p>
      <dl class="grid grid-cols-3 gap-4 px-4 pb-4 text-sm">
        <div>
          <dt class="text-base-content/70">nodes</dt>
          <dd class="font-mono text-base-content">
            <%= entry_text(Map.get(@cache, :node_cache, %{})) %>
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">listings</dt>
          <dd class="font-mono text-base-content">
            <%= entry_text(Map.get(@cache, :dir_cache, %{})) %>
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">total</dt>
          <dd class="font-mono text-base-content"><%= format_bytes(Map.get(@cache, :total_bytes)) %></dd>
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
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-teal-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Indexes</h2>

      <dl class="grid grid-cols-4 gap-4 px-4 pb-4 text-sm">
        <div>
          <dt class="text-base-content/70">vector</dt>
          <dd class="font-mono text-base-content"><%= vector_line(@coverage) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">active dim</dt>
          <dd class="font-mono text-base-content"><%= Map.get(@coverage, :active_dim, "—") %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">reclaimable</dt>
          <dd class="font-mono text-base-content"><%= Map.get(@coverage, :reclaimable, 0) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">missing from active dim</dt>
          <dd class="font-mono text-base-content"><%= missing_from_active(@coverage) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">code</dt>
          <dd class="font-mono text-base-content">
            <%= Map.get(@coverage, :code_documents, 0) %> docs
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">hex docs</dt>
          <dd class="font-mono text-base-content">
            <%= Map.get(@coverage, :hex_documents, 0) %> docs
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">locked packages</dt>
          <dd class="font-mono text-base-content">
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

  defp missing_from_active(coverage) do
    documents = Map.get(coverage, :documents, 0) || 0
    vectors = Map.get(coverage, :vectors, 0) || 0

    if Map.get(coverage, :available, false) do
      max(documents - vectors, 0)
    else
      "index not available"
    end
  end

  def operation_stats(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-blue-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Operation statistics</h2>
      <table class="w-full text-sm">
        <thead>
          <tr class="text-left text-base-content/70">
            <th class="px-4 py-2">operation</th>
            <th class="px-4 py-2">success</th>
            <th class="px-4 py-2">failure</th>
            <th class="px-4 py-2">error rate</th>
            <th class="px-4 py-2">p50</th>
            <th class="px-4 py-2">p95</th>
          </tr>
        </thead>
        <tbody>
          <%= for {{family, dimension}, info} <- @stats do %>
            <tr>
              <td class="px-4 py-2 font-mono"><%= Map.get(dimension, :operation) || Map.get(dimension, :kind) || family %></td>
              <td class="px-4 py-2"><%= Map.get(info, :success, 0) %></td>
              <td class="px-4 py-2"><%= Map.get(info, :failure, 0) %></td>
              <td class="px-4 py-2"><%= :erlang.float_to_binary(Map.get(info, :error_rate, 0.0) * 1.0, decimals: 2) %></td>
              <td class="px-4 py-2"><%= Map.get(info, :p50) %></td>
              <td class="px-4 py-2"><%= Map.get(info, :p95) %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </section>
    """
  end

  @doc "How long the node has been up, what it is running, and what has failed."
  def runtime(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-orange-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Runtime</h2>
      <p :if={@runtime[:error]} class="px-4 pb-2 text-sm text-base-content/70">
        A runtime snapshot could not be taken.
      </p>
      <dl :if={!@runtime[:error]} class="grid grid-cols-5 gap-4 px-4 pb-2 text-sm">
        <div>
          <dt class="text-base-content/70">uptime</dt>
          <dd class="font-mono text-base-content"><%= format_ms(Map.get(@runtime, :uptime_ms)) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">processes</dt>
          <dd class="font-mono text-base-content">
            <%= process_count(@runtime) %>
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">supervisors</dt>
          <dd class="font-mono text-base-content"><%= length(Map.get(@runtime, :supervisors, [])) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">ETS tables</dt>
          <dd class="font-mono text-base-content"><%= length(Map.get(@runtime, :ets, [])) %></dd>
        </div>
        <div>
          <dt class="text-base-content/70">BEAM memory</dt>
          <dd class="font-mono text-base-content">
            <%= format_bytes(Map.get(Map.get(@runtime, :memory, %{}), :total)) %>
          </dd>
        </div>
      </dl>

      <p class="px-4 pb-2 text-sm text-base-content/70">Recent failures</p>
      <ul :if={@errors == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No recorded failures</li>
      </ul>
      <ul id="recent-errors" :if={@errors != []} class="divide-y divide-base-200 border-t border-base-300">
        <li :for={entry <- @errors} class="flex items-center justify-between px-4 py-2 text-sm">
          <span class="font-mono text-base-content"><%= entry.operation || entry.family %></span>
          <span class="text-error"><%= entry.reason %></span>
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

  attr(:stats, :map, default: %{})

  def memory_stats(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-purple-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Memory statistics</h2>
      <p class="px-4 pb-2 text-sm text-base-content/70">per type</p>
      <ul class="px-4 pb-2 text-sm">
        <li :for={{type, count} <- Enum.sort(Map.get(@stats, :by_type, Map.get(@stats, :types, %{})))}><%= type %>: <%= count %></li>
      </ul>
      <p class="px-4 pb-2 text-sm text-base-content/70">per status</p>
      <ul class="px-4 pb-2 text-sm">
        <li :for={{status, count} <- Enum.sort(Map.get(@stats, :by_status, Map.get(@stats, :statuses, %{})))}><%= status %>: <%= count %></li>
      </ul>
      <p class="px-4 pb-2 text-sm text-base-content/70">waiting for review: <%= Map.get(@stats, :pending, Map.get(@stats, :waiting, 0)) %></p>
      <p class="px-4 pb-2 text-sm text-base-content/70">never surfaced: <%= Map.get(@stats, :never_surfaced, Map.get(@stats, :unsurfaced, 0)) %></p>
    </section>
    """
  end

  attr(:candidates, :list, default: [])

  def memory_candidates(assigns) do
    ~H"""
    <section class="card bg-base-100 shadow-md rounded-lg border-t-4 border-purple-500">
      <h2 class="card-title px-4 py-3 font-medium text-base-content">Waiting for review</h2>
      <ul :if={@candidates == []} class="px-4 pb-4 text-sm text-base-content/70">
        <li>No candidates waiting</li>
      </ul>
      <ul id="memory-candidates" :if={@candidates != []} class="divide-y divide-base-200">
        <li :for={m <- @candidates} class="px-4 py-2 text-sm">
          <span class="font-mono text-base-content"><%= m.uri %></span>
          <span class="text-base-content/80"><%= m.value %></span>
          <button phx-click="promote" phx-value-uri={m.uri} class="ml-2 text-green-700">Promote</button>
          <button phx-click="reject" phx-value-uri={m.uri} class="ml-2 text-error">Reject</button>
          <button phx-click="forget" phx-value-uri={m.uri} class="ml-2 text-base-content/80">Forget</button>
        </li>
      </ul>
    </section>
    """
  end
end
