defmodule AgentDbWeb.DocumentEditorLiveTest.FailingStorage do
  @moduledoc false
  # A storage that refuses a write, so the editor's failure path is exercised
  # with a real store error rather than a mocked one. Swapped in for the single
  # publish event and swapped back out.
  def put_document(_uri, _content, _opts), do: {:error, :invalid_uri}
end

defmodule AgentDbWeb.DocumentEditorLiveTest do
  @moduledoc """
  The document editor's publish path.

  Publishing either succeeds and says so, or fails and reports the store's
  classified reason. Either way the operator sees the outcome on the page they
  are left on, because the editor sets feedback through `put_flash`.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AgentDb.Cache
  alias AgentDbWeb.DocumentEditorLiveTest.FailingStorage

  @endpoint AgentDbWeb.Endpoint

  setup do
    endpoint = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])
    storage_adapter = Application.get_env(:agent_db, :storage_adapter)

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
      restore_storage_adapter(storage_adapter)
    end)

    :ok
  end

  test "a successful publish reports it on the page and stores the content" do
    uri = "viking://resources/editor/publish.md"
    :ok = AgentDb.write(uri, "the first draft")

    {:ok, view, _html} = live(build_conn(), edit_path(uri))

    view |> element("#document-draft") |> render_change(%{"draft" => "the published draft"})
    html = view |> form("form") |> render_submit()

    assert html =~ "Published"
    assert {:ok, "the published draft"} = AgentDb.read(uri)
  end

  test "a failed publish reports a classified reason, never the inspected term" do
    uri = "viking://resources/editor/fail.md"
    :ok = AgentDb.write(uri, "the first draft")

    {:ok, view, _html} = live(build_conn(), edit_path(uri))

    view |> element("#document-draft") |> render_change(%{"draft" => "will not persist"})

    html = with_failing_storage(fn -> view |> form("form") |> render_submit() end)

    assert html =~ "Could not publish: invalid_uri"
    refute html =~ ~r/Could not publish: \{/
    refute html =~ ~r/Could not publish: %/
  end

  # The store is made to refuse writes for exactly one publish, so the editor's
  # failure branch runs against a real `{:error, reason}` from the storage port.
  defp with_failing_storage(fun) do
    Application.put_env(:agent_db, :storage_adapter, FailingStorage)

    try do
      fun.()
    after
      Application.delete_env(:agent_db, :storage_adapter)
    end
  end

  defp restore_storage_adapter(nil), do: Application.delete_env(:agent_db, :storage_adapter)

  defp restore_storage_adapter(adapter),
    do: Application.put_env(:agent_db, :storage_adapter, adapter)

  defp edit_path(uri), do: "/admin/documents/#{URI.encode_www_form(uri)}/edit"

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  describe "a change underneath the open document" do
    test "a skill update refreshes the stored content without manual reload" do
      uri = "viking://user/alice/skills/alpha/SKILL.md"

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "v1 manifest"}]}
               )

      {:ok, view, _html} = live(build_conn(), edit_path(uri))
      assert render(view) =~ "v1 manifest"

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "v2 manifest"}]}
               )

      assert eventually(view, "v2 manifest") =~ "v2 manifest"
      assert {:ok, "v2 manifest"} = AgentDb.read(uri)
    end

    test "an unsaved draft survives a skill update and reports it" do
      uri = "viking://user/alice/skills/alpha/SKILL.md"

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "v1 manifest"}]}
               )

      {:ok, view, _html} = live(build_conn(), edit_path(uri))
      view |> element("#document-draft") |> render_change(%{"draft" => "my unsaved edit"})

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "v2 manifest"}]}
               )

      html = eventually(view, "Changed underneath")
      assert html =~ "my unsaved edit"
      assert html =~ "Changed underneath"
      assert html =~ "Unsaved changes"
    end

    test "a removed document keeps the draft and says it is gone" do
      uri = "viking://user/alice/skills/alpha/SKILL.md"

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "v1 manifest"}]}
               )

      {:ok, view, _html} = live(build_conn(), edit_path(uri))

      :ok = AgentDb.rm("viking://user/alice/skills/alpha")

      html = eventually(view, "No longer stored")
      assert html =~ "v1 manifest"
      assert html =~ "No longer stored"
    end

    test "an unrelated change leaves the open document alone" do
      uri = "viking://user/alice/skills/alpha/SKILL.md"

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "v1 manifest"}]}
               )

      {:ok, view, _html} = live(build_conn(), edit_path(uri))

      :ok = AgentDb.write("viking://resources/elsewhere/note.md", "unrelated")

      Process.sleep(300)
      html = render(view)
      assert html =~ "v1 manifest"
      refute html =~ "Changed underneath"
      refute html =~ "No longer stored"
    end
  end

  describe "the LLM view" do
    test "shows all three layers with sources and sizes" do
      uri = "viking://resources/editor/llm-view.md"
      :ok = AgentDb.write(uri, "full L2 body", abstract: "one-line L0", overview: "structured L1")

      {:ok, view, _html} = live(build_conn(), edit_path(uri))
      html = render(view)

      assert html =~ "How the LLM sees this document"
      assert html =~ "Abstract (L0)"
      assert html =~ "Overview (L1)"
      assert html =~ "Full content (L2)"
      assert html =~ "one-line L0"
      assert html =~ "structured L1"
      assert html =~ "full L2 body"
      assert html =~ "stored"
      assert html =~ "chars"
    end

    test "an external write refreshes the LLM view but keeps the unsaved draft" do
      uri = "viking://resources/editor/llm-refresh.md"
      :ok = AgentDb.write(uri, "v1 body", abstract: "v1 abstract")

      {:ok, view, _html} = live(build_conn(), edit_path(uri))
      view |> element("#document-draft") |> render_change(%{"draft" => "my unsaved edit"})

      :ok = AgentDb.write(uri, "v2 body", abstract: "v2 abstract")

      html = eventually(view, "v2 body")
      assert html =~ "my unsaved edit"
      assert html =~ "Changed underneath"
      assert html =~ "v2 abstract"
    end

    test "a removed document shows unavailable layers and keeps the draft" do
      uri = "viking://resources/editor/llm-gone.md"
      :ok = AgentDb.write(uri, "doomed body", abstract: "doomed abstract")

      {:ok, view, _html} = live(build_conn(), edit_path(uri))
      :ok = AgentDb.rm(uri)

      html = eventually(view, "No longer stored")
      assert html =~ "doomed body"
      assert html =~ "Not available."
    end
  end

  # PubSub delivery is async; poll the render until it converges or times out.
  defp eventually(view, expected \\ nil, tries \\ 20) do
    html = render(view)

    cond do
      is_nil(expected) -> html
      html =~ expected -> html
      tries <= 0 -> html
      true -> Process.sleep(100) && eventually(view, expected, tries - 1)
    end
  end
end
