defmodule AgentDbWeb.AdminLiveTest do
  @moduledoc """
  The console's skill import, through the two forms an operator can use.

  A LiveView test drives the same path a browser does -- the upload is sent as
  entries, consumed, and handed to the same facade the Mix task uses -- so what
  these assert is what an operator gets, not what the view would render if it
  were handed a result.

  Each test mounts the console page it exercises, because the console is now
  several pages: the import form is on `/admin/skills`, search on
  `/admin/documents`, the feed on `/admin`, and session lookup on
  `/admin/sessions`.
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

    :ok
  end

  # Mounting the page a test is about. A page mounts on connect, so a test that
  # writes first and mounts second sees what it wrote.
  defp page(path) do
    {:ok, view, _html} = live(build_conn(), path)
    view
  end

  describe "what the console offers" do
    test "names the fields the documentation tells an operator to fill in" do
      view = page("/admin/skills")
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
    test "imports the skills it holds and reports each one" do
      view = page("/admin/skills")

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

    test "a skill already stored is reported as replaced, and its old files go" do
      view = page("/admin/skills")

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

    test "selecting a folder lists its files before submit" do
      view = page("/admin/skills")

      # The form roundtrips selection (phx-change) and streams bytes on
      # select (auto-upload): in a browser this needs no submit, and the
      # test client drives the same server state via render_upload.
      upload =
        file_input(view, @form, :skill_folder, [
          %{name: "SKILL.md", relative_path: "alpha/SKILL.md", content: "the manifest"},
          %{name: "guide.md", relative_path: "alpha/references/guide.md", content: "the guide"}
        ])

      for entry <- upload.entries, do: render_upload(upload, entry["name"])

      html = render(view)
      assert html =~ ~s(phx-change="validate")
      assert html =~ "alpha/SKILL.md"
      assert html =~ "alpha/references/guide.md"
    end

    test "a folder with macOS metadata imports the skill and ignores the metadata" do
      view = page("/admin/skills")

      view =
        submit_folder(view, "alice", [
          %{name: "SKILL.md", relative_path: "alpha/SKILL.md", content: "the manifest"},
          %{name: "._SKILL.md", relative_path: "alpha/._SKILL.md", content: <<0xFF, 0xFE>>}
        ])

      assert render(view) =~ "1 imported"
      assert {:ok, "the manifest"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:ok, ["SKILL.md"]} = AgentDb.list("viking://user/alice/skills/alpha")
    end
  end

  describe "an archive upload" do
    test "imports the skills it holds" do
      view = page("/admin/skills")
      view = submit_archive(view, "alice", "skills.tar", archive([{"alpha/SKILL.md", "alpha\n"}]))

      assert render(view) =~ "1 imported"
      assert render(view) =~ "alpha"
      assert {:ok, "alpha\n"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end

    test "takes precedence over a folder filled in at the same time" do
      view = page("/admin/skills")

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
    test "is reported in words, and nothing is written" do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {
                 :uploads,
                 [%{path: "alpha/SKILL.md", content: "the stored manifest"}]
               })

      view = page("/admin/skills")

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

    test "a user id that could not be a URI segment is reported rather than stored under" do
      view = page("/admin/skills")
      view = submit_folder(view, "alice/../root", folder_skill("alpha"))

      assert render(view) =~ "Import refused"
      assert render(view) =~ "one URI segment"
    end
  end

  describe "an import with nothing chosen" do
    test "says what to choose" do
      view = page("/admin/skills")
      view |> form(@form, %{"user_id" => "alice"}) |> render_submit()

      assert render(view) =~ "Choose a skills folder or an archive"
    end
  end

  describe "realtime updates" do
    test "the first change event after mount reloads immediately" do
      view = page("/admin/documents")
      assert render(view) =~ "0 documents"

      :ok = AgentDb.write("viking://resources/first-event-note.md", "first event content")
      send(view.pid, {:context_changed, "viking://resources/first-event-note.md", :written, 1})

      # No coalesced refresh, no fallback refresh: the first event is not a
      # burst, so the page converges on the event itself.
      html = render(view)
      assert html =~ "1 documents"
      assert html =~ "resources"
    end

    test "a change event records URI, kind and version in the feed" do
      view = page("/admin")
      send(view.pid, {:context_changed, "viking://resources/realtime-note.md", :written, 7})

      html = render(view)
      assert html =~ "viking://resources/realtime-note.md"
      assert html =~ "written"
      assert html =~ "v7"
    end

    test "rapid bursts all land in the feed newest-first and converge on reload" do
      view = page("/admin")

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

    test "a missed event still converges on fallback refresh" do
      view = page("/admin")
      :ok = AgentDb.write("viking://resources/fallback-note.md", "fallback content")
      send(view.pid, :refresh)

      assert render(view) =~ "viking://resources/fallback-note.md"
    end

    test "the feed never carries document content" do
      :ok = AgentDb.write("viking://resources/secret-note.md", "super-secret-content-xyz")
      view = page("/admin")
      send(view.pid, {:context_changed, "viking://resources/secret-note.md", :written, 3})
      send(view.pid, :refresh_coalesced)

      html = render(view)
      assert html =~ "viking://resources/secret-note.md"
      refute html =~ "super-secret-content-xyz"
    end
  end

  describe "document search" do
    test "finds documents and links each to the editor" do
      :ok =
        AgentDb.write(
          "viking://resources/searchable/apple-pie.md",
          "apple pie recipe with plenty of cinnamon"
        )

      view = page("/admin/documents")

      view
      |> form("#doc-search", %{"term" => "cinnamon", "scope" => ""})
      |> render_submit()

      html = render(view)
      assert html =~ "viking://resources/searchable/apple-pie.md"
      assert html =~ "/admin/documents/"
    end

    test "a refused search reports in words and keeps the listing" do
      :ok = AgentDb.write("viking://resources/searchable/keep-me.md", "keep me visible")

      view = page("/admin/documents")

      view
      |> form("#doc-search", %{"term" => "keep", "scope" => "not-a-uri"})
      |> render_submit()

      html = render(view)
      assert html =~ "Search failed"
      # The listing is still there: its entries link to the editor, which a
      # refused search must not blank.
      assert html =~ "/admin/documents/"
    end
  end

  describe "model, queue and health status" do
    test "shows roles, queue breakdown and health checks" do
      view = page("/admin")
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
    test "shows messages for a known session" do
      {:ok, sid} = AgentDb.create_session()
      :ok = AgentDb.append_message(sid, :user, "hello session")

      view = page("/admin/sessions")
      view |> form("#session-lookup", %{"session_id" => sid}) |> render_submit()

      assert render(view) =~ "hello session"
    end

    test "reports an unknown session id" do
      view = page("/admin/sessions")
      view |> form("#session-lookup", %{"session_id" => "no-such-session"}) |> render_submit()

      assert render(view) =~ "No session with that ID"
    end
  end

  describe "a skill's LLM view" do
    test "expands to the skill's files with their layers and collapses again" do
      {:ok, _} =
        AgentDb.import_skills(
          "alice",
          {:uploads,
           [
             %{path: "alpha/SKILL.md", content: "alpha manifest line"},
             %{path: "alpha/notes.md", content: "alpha notes body"}
           ]}
        )

      view = page("/admin/skills")

      html = view |> element("button", "LLM view") |> render_click()

      assert html =~ "viking://user/alice/skills/alpha/SKILL.md"
      assert html =~ "viking://user/alice/skills/alpha/notes.md"
      assert html =~ "Abstract (L0)"
      assert html =~ "Overview (L1)"
      assert html =~ "Full content (L2)"
      assert html =~ "alpha manifest line"
      assert html =~ "alpha notes body"
      assert html =~ "chars"

      html = view |> element("button", "Hide LLM view") |> render_click()

      refute html =~ "alpha manifest line"
      refute html =~ "alpha notes body"
    end

    test "pages the skill's files fifty at a time" do
      numbered =
        for n <- 1..51 do
          name = "file-#{String.pad_leading(to_string(n), 2, "0")}.md"
          %{path: "big/#{name}", content: "body #{n}"}
        end

      files = [%{path: "big/SKILL.md", content: "big manifest"} | numbered]

      {:ok, _} = AgentDb.import_skills("alice", {:uploads, files})

      view = page("/admin/skills")
      html = view |> element("button", "LLM view") |> render_click()

      assert html =~ "Page 1 of 2"
      assert html =~ "file-01.md"
      refute html =~ "file-51.md"

      html = view |> element("button", "Next") |> render_click()

      assert html =~ "Page 2 of 2"
      assert html =~ "file-51.md"
    end

    test "a replaced skill converges the open LLM view" do
      {:ok, _} =
        AgentDb.import_skills(
          "alice",
          {:uploads, [%{path: "gamma/SKILL.md", content: "v1 manifest"}]}
        )

      view = page("/admin/skills")
      html = view |> element("button", "LLM view") |> render_click()
      assert html =~ "v1 manifest"

      {:ok, _} =
        AgentDb.import_skills(
          "alice",
          {:uploads, [%{path: "gamma/SKILL.md", content: "v2 manifest"}]}
        )

      send(view.pid, :refresh)
      html = render(view)

      assert html =~ "v2 manifest"
      refute html =~ "v1 manifest"
    end

    test "a removed file converges without breaking the remaining files" do
      {:ok, _} =
        AgentDb.import_skills(
          "alice",
          {:uploads,
           [
             %{path: "delta/SKILL.md", content: "kept manifest"},
             %{path: "delta/old.md", content: "gone body"}
           ]}
        )

      view = page("/admin/skills")
      html = view |> element("button", "LLM view") |> render_click()
      assert html =~ "kept manifest"
      assert html =~ "gone body"

      :ok = AgentDb.rm("viking://user/alice/skills/delta/old.md")
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ "kept manifest"
      refute html =~ "gone body"
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
    staging = AgentDb.Test.Scratch.dir("agent_db_live")

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
