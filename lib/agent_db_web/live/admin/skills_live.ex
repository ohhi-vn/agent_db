defmodule AgentDbWeb.Admin.SkillsLive do
  @moduledoc """
  The console's skills page: importing Agent Skills into a user's subtree,
  plus the installed-skill inventory.

  A folder selection or an archive is handed to the same importer the command
  line uses, and every skill's outcome is reported -- imported, replaced, or the
  reason it failed. A refused bundle writes nothing.

  The inventory lists installed skills across users with search, paging,
  grouping, and per-row plus bulk enable/disable and group assignment.
  """
  use AgentDbWeb.Admin

  alias AgentDb.Observability
  alias AgentDbWeb.AdminComponents

  @admin_page :skills
  @page_size 50

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = super(params, session, socket)
    {:ok, allow_skill_uploads(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    # Render-only: selecting files roundtrips here so the form lists entries,
    # progress, and entry errors before submit. Entries are consumed once, on
    # submit, never here.
    {:noreply, socket}
  end

  def handle_event("import_skills", params, socket) do
    case read_source(socket) do
      :empty ->
        {:noreply, assign(socket, results: [], notice: "Choose a skills folder or an archive.")}

      {:ok, source} ->
        {:noreply, import_skills(socket, params["user_id"] || "", source)}
    end
  end

  def handle_event("filter_skills", params, socket) do
    socket =
      socket
      |> assign(
        skills_substring: String.trim(params["substring"] || ""),
        skills_owner: String.trim(params["owner"] || ""),
        skills_group: String.trim(params["group"] || ""),
        skills_show_disabled: params["show_disabled"] in ["true", "on", "1"],
        skills_page: 1
      )
      |> load()

    {:noreply, socket}
  end

  def handle_event("skills_page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(skills_page: page) |> load()}
  end

  def handle_event("toggle_skill", %{"uri" => uri} = params, socket) do
    {:noreply, socket |> assign(notice: toggle(uri, params["enabled"])) |> load()}
  end

  def handle_event("bulk_disable_skills", _params, socket) do
    {:noreply, socket |> assign(notice: bulk_set_enabled(socket, false)) |> load()}
  end

  def handle_event("bulk_enable_skills", _params, socket) do
    {:noreply, socket |> assign(notice: bulk_set_enabled(socket, true)) |> load()}
  end

  def handle_event("set_skill_group", %{"uri" => uri, "group_tag" => tag}, socket) do
    {:noreply, socket |> assign(notice: set_group(uri, String.trim(tag || ""))) |> load()}
  end

  def handle_event("bulk_set_group_skills", %{"group_tag" => tag}, socket) do
    {:noreply, socket |> assign(notice: bulk_set_group(socket, String.trim(tag || ""))) |> load()}
  end

  def handle_event("toggle_llm_view", %{"uri" => uri}, socket) do
    socket =
      if socket.assigns[:llm_skill_uri] == uri do
        assign(socket, llm_skill_uri: nil, llm_page: 1)
      else
        assign(socket, llm_skill_uri: uri, llm_page: 1)
      end

    {:noreply, load(socket)}
  end

  def handle_event("llm_files_page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(llm_page: page) |> load()}
  end

  def load(socket) do
    socket
    |> assign(limits: AgentDb.skill_import_limits())
    |> assign_new(:user_id, fn -> "" end)
    |> assign_new(:results, fn -> [] end)
    |> assign_new(:skills_page, fn -> 1 end)
    |> assign_new(:skills_substring, fn -> "" end)
    |> assign_new(:skills_owner, fn -> "" end)
    |> assign_new(:skills_group, fn -> "" end)
    |> assign_new(:skills_show_disabled, fn -> false end)
    |> assign_new(:llm_skill_uri, fn -> nil end)
    |> assign_new(:llm_page, fn -> 1 end)
    |> assign(inventory: inventory(socket))
    |> assign(llm_view: llm_view(socket))
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-8">
      <header>
        <h1 class="text-2xl font-semibold text-gray-900">Skills</h1>
      </header>

      <p :if={@notice} class="rounded bg-blue-50 px-3 py-2 text-sm text-blue-900"><%= @notice %></p>

      <AdminComponents.import_skills
        uploads={@uploads}
        user_id={@user_id}
        limits={@limits}
        results={@results}
      />
      <AdminComponents.skills_inventory
        inventory={@inventory}
        substring={@skills_substring}
        owner={@skills_owner}
        group={@skills_group}
        show_disabled={@skills_show_disabled}
        llm_uri={@llm_skill_uri}
        llm_view={@llm_view}
      />
    </div>
    """
  end

  defp inventory(socket) do
    assigns = socket.assigns

    opts = %{
      "page" => assigns[:skills_page] || 1,
      "per_page" => @page_size,
      "substring" => assigns[:skills_substring] || "",
      "owner" => assigns[:skills_owner] || "",
      "group" => assigns[:skills_group] || "",
      "include_disabled" => assigns[:skills_show_disabled] || false
    }

    case Context.list_skills(opts) do
      {:ok, %{data: rows, meta: meta}} ->
        %{data: rows, meta: meta}

      {:error, _reason} ->
        %{data: [], meta: %{page: 1, per_page: @page_size, total: 0, total_pages: 1}}
    end
  end

  defp current_page_uris(socket) do
    case socket.assigns[:inventory] do
      %{data: rows} -> Enum.map(rows, & &1.uri)
      _ -> []
    end
  end

  # The expanded per-skill LLM view: every file under the skill root with the
  # layers the store answers for it. Recomputed in load/1, so change events
  # and the periodic refresh converge it like every other live section.
  defp llm_view(socket) do
    case socket.assigns[:llm_skill_uri] do
      nil -> nil
      "" -> nil
      uri -> skill_files(uri, socket.assigns[:llm_page] || 1)
    end
  end

  defp skill_files(uri, page) do
    opts = %{
      "scope" => uri,
      "page" => page,
      "per_page" => @page_size,
      "include_disabled" => true
    }

    case Context.list_all_documents(opts) do
      {:ok, %{data: rows, meta: meta}} ->
        %{
          uri: uri,
          files:
            Enum.map(rows, fn row -> %{uri: row.uri, layers: Context.get_layers(row.uri)} end),
          meta: meta
        }

      {:error, _reason} ->
        %{
          uri: uri,
          files: [],
          meta: %{page: 1, per_page: @page_size, total: 0, total_pages: 1},
          error: true
        }
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
        "#{verb} #{updated} skill(s)"

      {:ok, %{updated: updated, failed: failed}} ->
        "#{verb} #{updated} skill(s), #{failed} failed"

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
        "Set group for #{updated} skill(s) to #{group_word(tag)}"

      {:ok, %{updated: updated, failed: failed}} ->
        "Set group for #{updated} skill(s) to #{group_word(tag)}, #{failed} failed"

      {:error, reason} ->
        "Bulk action failed: #{Observability.error_message(reason)}"
    end
  end

  defp group_word(""), do: "ungrouped"
  defp group_word(tag), do: tag

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
      max_file_size: limits.max_bytes,
      auto_upload: true
    )
    |> allow_upload(:skill_archive,
      accept: :any,
      max_entries: 1,
      max_file_size: limits.max_bytes,
      auto_upload: true
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
end
