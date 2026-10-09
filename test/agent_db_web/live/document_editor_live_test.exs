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
end
