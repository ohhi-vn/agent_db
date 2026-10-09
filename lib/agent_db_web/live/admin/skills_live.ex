defmodule AgentDbWeb.Admin.SkillsLive do
  @moduledoc """
  The console's skills page: importing Agent Skills into a user's subtree.

  A folder selection or an archive is handed to the same importer the command
  line uses, and every skill's outcome is reported -- imported, replaced, or the
  reason it failed. A refused bundle writes nothing.
  """
  use AgentDbWeb.Admin

  alias AgentDbWeb.AdminComponents

  @admin_page :skills

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok, socket} = super(params, session, socket)
    {:ok, allow_skill_uploads(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("import_skills", params, socket) do
    case read_source(socket) do
      :empty ->
        {:noreply, assign(socket, results: [], notice: "Choose a skills folder or an archive.")}

      {:ok, source} ->
        {:noreply, import_skills(socket, params["user_id"] || "", source)}
    end
  end

  def load(socket) do
    socket
    |> assign(limits: AgentDb.skill_import_limits())
    |> assign_new(:user_id, fn -> "" end)
    |> assign_new(:results, fn -> [] end)
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
    </div>
    """
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
end
