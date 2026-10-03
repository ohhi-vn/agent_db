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

  # -- recent changes --

  attr(:changes, :list, required: true)

  @doc "The recent-change feed: URI, kind, and version only."
  def recent_changes(assigns) do
    ~H"""
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Recent changes</h2>
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
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Models</h2>
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
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Queue</h2>
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
    """
  end

  # -- sessions --

  attr(:session_id, :string, default: "")
  attr(:messages, :list, default: [])
  attr(:notice, :string, default: nil)

  @doc "Looking a session up by id; the store keeps no index to list them by."
  def session_lookup(assigns) do
    ~H"""
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
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Documents</h2>
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

  # -- storage, cache, indexes, runtime --

  attr(:storage, :map, required: true)
  attr(:cache, :map, required: true)

  @doc "What the store holds, and how much of that is the cache rather than content."
  def footprint(assigns) do
    ~H"""
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Storage</h2>
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
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Indexes</h2>
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
    <section class="rounded-lg border border-gray-200">
      <h2 class="px-4 py-3 font-medium text-gray-900">Runtime</h2>
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
