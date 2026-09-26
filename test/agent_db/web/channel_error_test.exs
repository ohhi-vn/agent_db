defmodule AgentDb.WebChannelErrorTest do
  use ExUnit.Case, async: false

  # handle_in/3 is a plain function returning {:reply, payload, socket}, so the
  # error contract can be exercised without standing up a channel harness.
  alias AgentDb.WebChannel

  setup do
    :ok = Supervisor.terminate_child(AgentDb.Supervisor, AgentDb.ML.ModelManager)
    cache = Path.join(System.tmp_dir!(), "agent_db_chan_#{:erlang.unique_integer([:positive])}")

    Application.put_env(:agent_db, :model_cache_dir, cache)
    Application.put_env(:agent_db, :embedding_model, "test/model-#{:erlang.unique_integer([:positive])}")
    Application.put_env(:agent_db, :model_load_grace_ms, 50)
    # A manager with no model and no reachable download, so a search is
    # genuinely unservable rather than absent.
    start_supervised!({AgentDb.ML.ModelManager, []})

    on_exit(fn ->
      for key <- [:model_cache_dir, :embedding_model, :model_load_grace_ms] do
        Application.delete_env(:agent_db, key)
      end

      File.rm_rf(cache)
      Supervisor.restart_child(AgentDb.Supervisor, AgentDb.ML.ModelManager)
    end)

    :ok
  end

  defp search(mode), do: WebChannel.handle_in("v1.search", %{"term" => "x", "opts" => %{"mode" => mode}}, %Phoenix.Socket{})

  test "a search that cannot be served returns an error, not a crash" do
    assert {:reply, {:error, %{reason: reason}}, _socket} = search("vector")
    assert reason != nil
  end

  test "a deferred search is distinguishable from one that failed" do
    {:reply, {:error, %{reason: deferred}}, _} = search("vector")

    # Whether this call observed :model_loading or a classified failure depends
    # on how far the load got inside the grace period. Either way the payload
    # must not be an opaque crash, and the two outcomes must be told apart by
    # their shape: a bare atom versus a tagged tuple.
    assert deferred == :model_loading or match?({tag, _} when is_atom(tag), deferred)
  end

  # Options arrive over the wire as a string-keyed JSON map. The store reads
  # them with Keyword.get/2,3, so passing the map through untouched raised
  # FunctionClauseError and took the channel down on every one of these calls.
  describe "JSON options" do
    test "v1.search accepts a string-keyed options map" do
      assert {:reply, {:ok, %{results: _}}, _} =
               WebChannel.handle_in(
                 "v1.search",
                 %{"term" => "hello", "opts" => %{"mode" => "keyword", "top_k" => 5}},
                 %Phoenix.Socket{}
               )
    end

    test "v1.write accepts a string-keyed options map" do
      assert {:reply, {:ok, _}, _} =
               WebChannel.handle_in(
                 "v1.write",
                 %{
                   "uri" => "viking://resources/chan/a.md",
                   "content" => "hello",
                   "opts" => %{"async" => true, "abstract" => "L0"}
                 },
                 %Phoenix.Socket{}
               )
    end

    test "v1.commit_session accepts a string-keyed options map" do
      {:ok, sid} = AgentDb.create_session()
      :ok = AgentDb.append_message(sid, :user, "hi")

      assert {:reply, {:ok, _}, _} =
               WebChannel.handle_in(
                 "v1.commit_session",
                 %{
                   "session_id" => sid,
                   "destination_uri" => "viking://user/u1/memories/chan-1",
                   "opts" => %{}
                 },
                 %Phoenix.Socket{}
               )
    end

    test "an unrecognised option is ignored rather than mistyped" do
      assert {:reply, {:ok, %{results: _}}, _} =
               WebChannel.handle_in(
                 "v1.search",
                 %{"term" => "hello", "opts" => %{"modee" => "vector"}},
                 %Phoenix.Socket{}
               )
    end
  end

  test "the connection is still usable after an unservable call" do
    {:reply, _, socket} = search("vector")

    # A subsequent keyword search on the same socket is unaffected.
    assert {:reply, {:ok, %{results: _}}, ^socket} =
             WebChannel.handle_in("v1.search", %{"term" => "x", "opts" => %{"mode" => "keyword"}}, socket)
  end
end
