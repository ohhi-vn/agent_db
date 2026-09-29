defmodule AgentDbWeb.AdminLive do
  @moduledoc """
  The operations console.

  A view of what the store holds and what it is doing, and the place an operator
  imports Agent Skills from. It answers through the same facade every other client
  uses, so what an operator does here is what a program gets -- there is no second,
  more forgiving path into the store for the console's benefit.
  """
  use Phoenix.LiveView, layout: {AgentDbWeb.Layouts, :live}

  import Phoenix.LiveView
  import Phoenix.Component

  alias AgentDbWeb.Context

  @refresh_ms 30_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_ms, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(page: 1, user_id: "", results: [], limits: AgentDb.skill_import_limits())
     |> allow_skill_uploads()
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"page" => page}, _uri, socket) do
    {:noreply, socket |> assign(page: page) |> load()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_event("delete", %{"uri" => uri}, socket) do
    {:noreply, socket |> assign(notice: delete(uri)) |> load()}
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

  defp load(socket) do
    assign(socket,
      documents: documents(socket.assigns.page),
      models: Context.model_status(),
      jobs: Context.job_stats(),
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

      <section :for={{_title, _model} <- models_summary(@models)} class="rounded-lg border border-gray-200">
        <h2 class="px-4 py-3 font-medium text-gray-900">Models</h2>
        <dl class="grid grid-cols-2 gap-4 px-4 pb-4 text-sm">
          <div :for={{role, entry} <- models_summary(@models)}>
            <dt class="text-gray-500"><%= role %></dt>
            <dd class="font-mono text-gray-900">
              <%= entry.state %> &middot; <%= entry.loaded && "loaded" || "not loaded" %>
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
end
