defmodule AgentDbWeb.AdminLiveTest do
  @moduledoc """
  The console's skill import, through the two forms an operator can use.

  A LiveView test drives the same path a browser does -- the upload is sent as
  entries, consumed, and handed to the same facade the Mix task uses -- so what
  these assert is what an operator gets, not what the view would render if it
  were handed a result.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AgentDb.Cache

  @endpoint AgentDbWeb.Endpoint
  @form "#import-skills"

  setup do
    endpoint = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

    # The console is served in-process: a listener bound to a port would collide
    # with a development instance, and a test of a LiveView needs no socket.
    Application.put_env(
      :agent_db,
      AgentDbWeb.Endpoint,
      Keyword.merge(endpoint, server: false, http: false)
    )

    start_supervised!(AgentDbWeb.Endpoint)

    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.put_env(:agent_db, AgentDbWeb.Endpoint, endpoint)
      Application.delete_env(:agent_db, :data_dir)
    end)

    {:ok, view, _html} = live(build_conn(), "/admin")
    {:ok, %{view: view}}
  end

  describe "what the console offers" do
    test "names the fields the documentation tells an operator to fill in", %{view: view} do
      limits = AgentDb.skill_import_limits()

      for label <- ["User ID", "Skills folder", "Skills archive", "Import skills"] do
        assert render(view) =~ label
      end

      # The caps the console applies are the importer's own, shown so that an
      # operator can tell a refused upload from a refused bundle.
      assert render(view) =~ to_string(limits.max_entries)
      assert render(view) =~ to_string(limits.max_bytes)
    end
  end

  describe "a folder selection" do
    test "imports the skills it holds and reports each one", %{view: view} do
      view =
        submit_folder(view, "alice", [
          %{name: "SKILL.md", relative_path: "my-skills/alpha/SKILL.md", content: "the manifest"},
          %{
            name: "guide.md",
            relative_path: "my-skills/alpha/references/guide.md",
            content: "the guide"
          },
          %{
            name: "SKILL.md",
            relative_path: "my-skills/beta/SKILL.md",
            content: "beta's manifest"
          }
        ])

      assert render(view) =~ "2 imported"
      assert render(view) =~ "alpha"
      assert render(view) =~ "beta"

      assert {:ok, "the manifest"} =
               AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")

      assert {:ok, "the guide"} =
               AgentDb.read("viking://user/alice/skills/alpha/references/guide.md")

      assert {:ok, "beta's manifest"} = AgentDb.read("viking://user/alice/skills/beta/SKILL.md")
    end

    test "a skill already stored is reported as replaced, and its old files go", %{view: view} do
      submit_folder(view, "alice", [
        %{name: "SKILL.md", relative_path: "alpha/SKILL.md", content: "the manifest"},
        %{name: "old.md", relative_path: "alpha/old.md", content: "the old file"}
      ])

      view =
        submit_folder(view, "alice", [
          %{name: "SKILL.md", relative_path: "alpha/SKILL.md", content: "a newer manifest"}
        ])

      assert render(view) =~ "1 replaced"

      assert {:ok, "a newer manifest"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:error, :not_found} = AgentDb.read("viking://user/alice/skills/alpha/old.md")
    end
  end

  describe "an archive upload" do
    test "imports the skills it holds", %{view: view} do
      view = submit_archive(view, "alice", "skills.tar", archive([{"alpha/SKILL.md", "alpha\n"}]))

      assert render(view) =~ "1 imported"
      assert render(view) =~ "alpha"
      assert {:ok, "alpha\n"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end

    test "takes precedence over a folder filled in at the same time", %{view: view} do
      # An archive is one file and a folder is many, so the importer takes the
      # archive when both are filled in rather than reading the folder as well.
      folder =
        file_input(
          view,
          @form,
          :skill_folder,
          named([
            %{
              name: "SKILL.md",
              relative_path: "folder-skill/SKILL.md",
              content: "from the folder"
            }
          ])
        )

      for entry <- folder.entries, do: render_upload(folder, entry["name"])

      archive =
        file_input(view, @form, :skill_archive, [
          %{name: "skills.tar", content: archive([{"archived/SKILL.md", "from the archive\n"}])}
        ])

      render_upload(archive, "skills.tar")

      view |> form(@form, %{"user_id" => "alice"}) |> render_submit()

      assert render(view) =~ "1 imported"

      assert {:ok, "from the archive\n"} =
               AgentDb.read("viking://user/alice/skills/archived/SKILL.md")

      assert {:error, :not_found} =
               AgentDb.read("viking://user/alice/skills/folder-skill/SKILL.md")
    end
  end

  describe "a source the importer refuses" do
    test "is reported in words, and nothing is written", %{view: view} do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {
                 :uploads,
                 [%{path: "alpha/SKILL.md", content: "the stored manifest"}]
               })

      view =
        submit_folder(view, "alice", [
          %{name: "SKILL.md", relative_path: "alpha/SKILL.md", content: "a newer manifest"},
          %{name: "escape.md", relative_path: "../escape.md", content: "nope"}
        ])

      assert render(view) =~ "Import refused"
      assert render(view) =~ "escape.md"
      refute render(view) =~ "imported"

      assert {:ok, "the stored manifest"} =
               AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")

      assert {:error, :not_found} = AgentDb.read("viking://resources/escape.md")
    end

    test "a user id that could not be a URI segment is reported rather than stored under", %{
      view: view
    } do
      view = submit_folder(view, "alice/../root", folder_skill("alpha"))

      assert render(view) =~ "Import refused"
      assert render(view) =~ "one URI segment"
    end
  end

  describe "an import with nothing chosen" do
    test "says what to choose", %{view: view} do
      view |> form(@form, %{"user_id" => "alice"}) |> render_submit()

      assert render(view) =~ "Choose a skills folder or an archive"
    end
  end

  describe "realtime updates" do
    test "a change event records URI, kind and version in the feed", %{view: view} do
      send(view.pid, {:context_changed, "viking://resources/realtime-note.md", :written, 7})

      html = render(view)
      assert html =~ "viking://resources/realtime-note.md"
      assert html =~ "written"
      assert html =~ "v7"
    end

    test "rapid bursts all land in the feed newest-first and converge on reload", %{view: view} do
      for n <- 1..5 do
        send(view.pid, {:context_changed, "viking://resources/burst-#{n}.md", :written, n})
      end

      # The burst coalesces reloads; forcing the deferred reload converges.
      send(view.pid, :refresh_coalesced)

      html = render(view)

      for n <- 1..5 do
        assert html =~ "burst-#{n}.md"
      end

      {later, _} = :binary.match(html, "burst-5.md")
      {earlier, _} = :binary.match(html, "burst-1.md")
      assert later < earlier
    end

    test "a missed event still converges on fallback refresh", %{view: view} do
      :ok = AgentDb.write("viking://resources/fallback-note.md", "fallback content")
      send(view.pid, :refresh)

      assert render(view) =~ "viking://resources/fallback-note.md"
    end

    test "the feed never carries document content", %{view: view} do
      :ok = AgentDb.write("viking://resources/secret-note.md", "super-secret-content-xyz")
      send(view.pid, {:context_changed, "viking://resources/secret-note.md", :written, 3})
      send(view.pid, :refresh_coalesced)

      html = render(view)
      assert html =~ "viking://resources/secret-note.md"
      refute html =~ "super-secret-content-xyz"
    end
  end

  describe "document search" do
    test "finds documents and links each to the editor", %{view: view} do
      :ok =
        AgentDb.write(
          "viking://resources/searchable/apple-pie.md",
          "apple pie recipe with plenty of cinnamon"
        )

      view
      |> form("#doc-search", %{"term" => "cinnamon", "scope" => ""})
      |> render_submit()

      html = render(view)
      assert html =~ "viking://resources/searchable/apple-pie.md"
      assert html =~ "/admin/documents/"
    end

    test "a refused search reports in words and keeps the listing", %{view: view} do
      :ok = AgentDb.write("viking://resources/searchable/keep-me.md", "keep me visible")
      send(view.pid, :refresh)

      view
      |> form("#doc-search", %{"term" => "keep", "scope" => "not-a-uri"})
      |> render_submit()

      html = render(view)
      assert html =~ "Search failed"
      assert html =~ "viking://resources/searchable/keep-me.md"
    end
  end

  describe "model, queue and health status" do
    test "shows roles, queue breakdown and health checks", %{view: view} do
      html = render(view)

      assert html =~ "Models"
      assert html =~ "embedding"
      assert html =~ "llm"
      assert html =~ "Provider"
      assert html =~ "Last inference"
      assert html =~ "Memory (BEAM total)"
      assert html =~ "Queue"

      for status <- ["pending", "running", "done", "failed"] do
        assert html =~ status
      end

      assert html =~ "Health"
    end
  end

  describe "session lookup" do
    test "shows messages for a known session", %{view: view} do
      {:ok, sid} = AgentDb.create_session()
      :ok = AgentDb.append_message(sid, :user, "hello session")

      view |> form("#session-lookup", %{"session_id" => sid}) |> render_submit()

      assert render(view) =~ "hello session"
    end

    test "reports an unknown session id", %{view: view} do
      view |> form("#session-lookup", %{"session_id" => "no-such-session"}) |> render_submit()

      assert render(view) =~ "No session with that ID"
    end
  end

  # -- helpers --

  # An entry is uploaded by its file name, so a folder of skills -- where two
  # files are both called SKILL.md -- is sent with names the test can tell apart.
  # What the importer reads is the relative path, which is what a browser sends
  # and what these entries carry.
  # A submit answers with the rendered result, so the view is returned and read
  # again: what the operator would see is the view after the event, not the
  # fragment the submit itself rendered.
  defp submit_folder(view, user_id, files) do
    upload = file_input(view, @form, :skill_folder, named(files))

    for entry <- upload.entries, do: render_upload(upload, entry["name"])

    view |> form(@form, %{"user_id" => user_id}) |> render_submit()
    view
  end

  defp submit_archive(view, user_id, name, contents) do
    upload = file_input(view, @form, :skill_archive, [%{name: name, content: contents}])
    render_upload(upload, name)
    view |> form(@form, %{"user_id" => user_id}) |> render_submit()
    view
  end

  defp named(files) do
    for {file, position} <- Enum.with_index(files) do
      Map.put(file, :name, "uploaded-#{position}")
    end
  end

  defp folder_skill(name) do
    [%{name: "SKILL.md", relative_path: "#{name}/SKILL.md", content: "the manifest"}]
  end

  defp archive(members) do
    staging = Path.join(System.tmp_dir!(), "agent_db_live_#{System.unique_integer([:positive])}")

    for {name, content} <- members do
      path = Path.join(staging, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    path = Path.join(staging, "skills.tar")

    :ok =
      File.cd!(staging, fn ->
        :erl_tar.create(
          String.to_charlist(path),
          Enum.map(members, fn {name, _content} -> String.to_charlist(name) end)
        )
      end)

    File.read!(path)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
