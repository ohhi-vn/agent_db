defmodule AgentDbWeb.AdminConsoleTest do
  @moduledoc """
  What the operations console reports, beyond the import form.

  The console is the operator's only view of the store, so the assertions here
  are about it telling the truth: the count it shows is the count the store
  holds, a page it cannot serve still renders, an index it cannot query is
  reported as unavailable rather than as empty, and a failure is described in
  the store's own taxonomy rather than as an internal term.

  Each test writes first and mounts second, because the console loads its
  sections on connect; a view mounted before the write would be reporting on a
  store that had not changed yet, which is a different question.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias AgentDb.Adapters.SQLite
  alias AgentDb.Cache

  @endpoint AgentDbWeb.Endpoint

  setup do
    endpoint = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

    Application.put_env(
      :agent_db,
      AgentDbWeb.Endpoint,
      Keyword.merge(endpoint, server: false, http: false)
    )

    start_supervised!(AgentDbWeb.Endpoint)

    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart()

    on_exit(fn ->
      Application.put_env(:agent_db, AgentDbWeb.Endpoint, endpoint)
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  defp restart do
    Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  defp console(params \\ "") do
    {:ok, view, html} = live(build_conn(), "/admin" <> params)
    {view, html}
  end

  defp exhaust_retries(job_id) do
    for _attempt <- 1..5 do
      assert {:ok, _job} = SQLite.dequeue_job([:embed])
      assert :ok = SQLite.fail_job(job_id, "inference_failed")
      make_runnable(job_id)
    end
  end

  # A job rescheduled with backoff is not claimable until its scheduled time, so
  # a retry loop has to bring it forward rather than wait out the backoff.
  defp make_runnable(job_id) do
    AgentDb.Store.Writer.call(fn conn ->
      AgentDb.Store.SQLite.exec_write(
        conn,
        "UPDATE job_queue SET scheduled_at = 1 WHERE id = ?",
        [job_id]
      )
    end)
  end

  describe "the document count" do
    test "is the number of documents the store holds" do
      for n <- 1..3 do
        :ok = AgentDb.write("viking://resources/count/doc#{n}.md", "body #{n}")
      end

      {_view, html} = console()

      assert html =~ "3 documents"
    end

    test "counts documents held in a nested subtree" do
      :ok = AgentDb.write("viking://resources/count/deep/inner/a.md", "a")
      :ok = AgentDb.write("viking://resources/count/deep/inner/b.md", "b")

      {_view, html} = console()

      assert html =~ "2 documents"
    end

    test "an empty store reports no documents rather than failing" do
      {_view, html} = console()

      assert html =~ "0 documents"
    end
  end

  describe "paging" do
    test "an invalid page renders a bounded page rather than failing" do
      :ok = AgentDb.write("viking://resources/page/doc.md", "body")

      # Each of these is a request a browser could produce: a page that is not a
      # number, one before the first, one past the last, one empty.
      for page <- ["abc", "0", "-1", "99", ""] do
        assert {:ok, _view, html} = live(build_conn(), "/admin?page=#{page}")
        assert html =~ "Documents"
      end
    end

    test "the listing still holds its entries after an invalid page" do
      :ok = AgentDb.write("viking://resources/page/doc.md", "body")

      # The listing is of names at the tree root, so a store with content under
      # `resources` lists `resources` -- and must still list it when the page
      # asked for could not be served.
      assert {:ok, _view, html} = live(build_conn(), "/admin?page=not-a-number")
      assert html =~ "resources"
      assert html =~ "1 documents"
    end
  end

  describe "operational sections" do
    test "report storage composition" do
      :ok = AgentDb.write("viking://resources/section/a.md", "a")

      {_view, html} = console()

      assert html =~ "Storage"
      assert html =~ "documents"
      assert html =~ "resources"
    end

    test "report cache size" do
      {_view, html} = console()

      assert html =~ "Cache"
      assert html =~ "listings"
    end

    test "report index coverage" do
      {_view, html} = console()

      assert html =~ "Indexes"
      assert html =~ "vector"
      assert html =~ "code"
    end

    test "report model state with load duration and in-flight count" do
      {_view, html} = console()

      assert html =~ "Models"
      assert html =~ "Last load"
      assert html =~ "In flight"
    end

    test "report queue depth and the oldest pending job" do
      {_view, html} = console()

      assert html =~ "Queue"
      assert html =~ "oldest pending"
    end

    test "report runtime liveness and recent failures" do
      {_view, html} = console()

      assert html =~ "Runtime"
      assert html =~ "uptime"
      assert html =~ "Recent failures"
    end

    test "an unavailable vector index reads as unavailable, not as empty" do
      {_view, html} = console()

      # sqlite-vec is optional at runtime. "Not available" and "nothing indexed"
      # are different facts, and the section has to be able to tell them apart.
      if AgentDb.Adapters.SQLite.vector_index_stats() |> elem(1) |> Map.get(:available) do
        assert html =~ "of"
      else
        assert html =~ "index not available"
      end
    end
  end

  describe "failed jobs" do
    test "are listed with their kind, uri, attempts, and classified reason" do
      uri = "viking://resources/jobs/gives-up.md"
      assert {:ok, job_id} = SQLite.enqueue_job(:embed, %{uri: uri, content: "x"})
      exhaust_retries(job_id)

      {_view, html} = console()

      assert html =~ "gives-up.md"
      assert html =~ "embed"
      assert html =~ "inference_failed"
      assert html =~ "5/5"
    end

    test "a queue with no failures says so" do
      {_view, html} = console()

      assert html =~ "No failed jobs"
    end
  end

  describe "how a failure is described" do
    test "a refused search shows a classified reason rather than a raw term" do
      {view, _html} = console()

      html =
        view
        |> form("#doc-search", %{"term" => "anything", "scope" => ""})
        |> render_submit()

      # Either the search served, or it reported a reason from the shared
      # taxonomy. What it must never do is print the failure term itself.
      refute html =~ "Search failed: {:"
      refute html =~ "Search failed: %"
    end

    test "an unknown session reports that rather than showing an error term" do
      {view, _html} = console()

      html =
        view
        |> form("#session-lookup", %{"session_id" => "no-such-session"})
        |> render_submit()

      assert html =~ "No session with that ID"
      refute html =~ "{:error"
    end

    test "removing a listed entry says what happened, without a raw failure term" do
      :ok = AgentDb.write("viking://resources/gone.md", "x")
      {view, _html} = console()

      # The button carries the full URI of the listed entry, which is what the
      # store can resolve -- a bare name would report `invalid_uri` for an entry
      # the operator can see.
      html =
        view
        |> element(~s{[phx-click="delete"][phx-value-uri="viking://resources"]})
        |> render_click()

      assert html =~ "Removed viking://resources"
      refute html =~ "{:error,"
    end
  end
end
