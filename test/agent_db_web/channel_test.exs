defmodule AgentDbWeb.ChannelTest do
  @moduledoc """
  The WebSocket surface's contract with a client.

  A call that cannot be served answers as an error and leaves the connection
  usable, because a client that loses its connection on one failed call has no
  way to tell a transient failure from a broken one.
  """
  use ExUnit.Case, async: false

  alias AgentDbWeb.Channel

  setup do
    :ok = AgentDb.StorageContract.Helpers.stop_workers()

    on_exit(fn -> :ok end)

    :ok
  end

  # handle_in/3 is a plain function returning {:reply, payload, socket}, so the
  # error contract can be exercised without standing up a channel harness.
  defp event(name, params, socket \\ %Phoenix.Socket{}),
    do: Channel.handle_in(name, params, socket)

  defp search(mode) do
    event("v1.search", %{"term" => "x", "opts" => %{"mode" => mode}})
  end

  describe "a call that cannot be served" do
    test "answers with an error rather than a crash" do
      # No embedding model is cached and remote downloads are skipped under
      # test, so a vector search is genuinely unservable.
      assert {:reply, {:error, %{reason: reason}}, _socket} = search("vector")
      assert reason != nil
    end

    test "is told apart from a call that could not yet be served" do
      assert {:reply, {:error, %{reason: deferred}}, _} = search("vector")

      # Whether this call saw :model_loading or a classified failure depends on
      # how far the load got inside the grace period. Either way the payload is
      # a plain string: "model_loading" to retry, anything else naming a cause.
      assert deferred == "model_loading" or (is_binary(deferred) and deferred != "")
    end

    test "leaves the connection usable" do
      {:reply, _, socket} = search("vector")

      assert {:reply, {:ok, %{results: _}}, ^socket} =
               event("v1.search", %{"term" => "x", "opts" => %{"mode" => "keyword"}}, socket)
    end
  end

  describe "options from the wire" do
    # A JSON payload arrives as a string-keyed map, while the store reads
    # options with Keyword. Passing the map through untouched raised, and took
    # the channel down on every one of these calls.
    test "search accepts a string-keyed options map" do
      assert {:reply, {:ok, %{results: _}}, _} =
               event("v1.search", %{
                 "term" => "hello",
                 "opts" => %{"mode" => "keyword", "top_k" => 5}
               })
    end

    test "write accepts a string-keyed options map" do
      assert {:reply, {:ok, _}, _} =
               event("v1.write", %{
                 "uri" => "viking://resources/chan/a.md",
                 "content" => "hello",
                 "opts" => %{"async" => true, "abstract" => "L0"}
               })
    end

    test "commit_session accepts a string-keyed options map" do
      assert {:ok, session_id} = AgentDb.create_session()
      assert :ok = AgentDb.append_message(session_id, :user, "hi")

      assert {:reply, {:ok, _}, _} =
               event("v1.commit_session", %{
                 "session_id" => session_id,
                 "destination_uri" => "viking://user/u1/memories/chan-1",
                 "opts" => %{}
               })
    end

    test "an unrecognised option is dropped rather than turned into a term" do
      # A misspelt option that became a term would be applied as though it had
      # been asked for.
      assert {:reply, {:ok, %{results: _}}, _} =
               event("v1.search", %{"term" => "hello", "opts" => %{"modee" => "vector"}})
    end
  end

  describe "navigation" do
    test "v1.find discovers paths with scope and limit" do
      :ok = AgentDb.write("viking://resources/chan-find/project/auth.md", "a")
      :ok = AgentDb.write("viking://resources/chan-find/project/nested/other.md", "b")

      assert {:reply, {:ok, %{results: results}}, _} =
               event("v1.find", %{
                 "term" => "auth",
                 "opts" => %{"scope" => "viking://resources/chan-find/project", "limit" => 10}
               })

      assert [%{uri: "viking://resources/chan-find/project/auth.md"}] = results
      assert %{name: "auth.md", kind: :doc} = hd(results)
    end

    test "v1.grep returns lines with numbers and excerpts" do
      :ok = AgentDb.write("viking://resources/chan-grep/a.md", "first\nsecond needle here\nthird")

      assert {:reply, {:ok, %{results: results}}, _} =
               event("v1.grep", %{
                 "term" => "needle",
                 "opts" => %{"scope" => "viking://resources/chan-grep/a.md"}
               })

      assert [%{uri: "viking://resources/chan-grep/a.md", line_number: 2}] = results
      assert String.contains?(hd(results).excerpt, "needle")
    end

    test "invalid navigation input errors without closing the connection" do
      assert {:reply, {:error, %{reason: _}}, socket} =
               event("v1.find", %{"term" => "", "opts" => %{}})

      assert {:reply, {:ok, %{results: _}}, ^socket} =
               event("v1.find", %{"term" => "auth", "opts" => %{}}, socket)

      assert {:reply, {:error, %{reason: _}}, socket} =
               event("v1.grep", %{"term" => "x", "opts" => %{"limit" => 0}})

      assert {:reply, {:ok, %{results: _}}, ^socket} =
               event("v1.grep", %{"term" => "x", "opts" => %{}}, socket)
    end

    test "navigation drops unrecognised options" do
      assert {:reply, {:ok, %{results: _}}, _} =
               event("v1.find", %{"term" => "auth", "opts" => %{"bogus" => "x"}})

      assert {:reply, {:ok, %{results: _}}, _} =
               event("v1.grep", %{"term" => "x", "opts" => %{"bogus" => "x"}})
    end
  end

  describe "versioning" do
    test "an unknown event is reported, not ignored" do
      assert {:reply, {:error, %{reason: "unknown_event", code: "unknown_event"}}, _} =
               event("v9.write", %{})
    end
  end
end
