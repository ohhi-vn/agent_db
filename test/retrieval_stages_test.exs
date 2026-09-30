defmodule AgentDb.RetrievalStagesTest do
  use ExUnit.Case, async: false

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok = AgentDb.StorageContract.Helpers.stop_workers()
    :ok
  end

  test "stage measurements use bounded dimensions without URIs or content" do
    test_pid = self()

    :telemetry.attach(
      "retrieval-stages-test",
      [:agent_db, :operation, :stop],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      :ok = AgentDb.write("viking://resources/stages/a.md", "secret content here")
      {:ok, _} = AgentDb.search("secret", mode: :keyword)

      events = collect_telemetry([])

      assert Enum.any?(events, fn {_e, _m, meta} -> meta[:operation] == :resource_search end)
      assert Enum.any?(events, fn {_e, _m, meta} -> meta[:operation] == :intent end)
      assert Enum.any?(events, fn {_e, _m, meta} -> meta[:operation] == :memory_search end)

      for {_e, _m, meta} <- events do
        refute Map.has_key?(meta, :uri)
        refute Map.has_key?(meta, :content)
        refute Map.has_key?(meta, :prompt)
      end

      blob = inspect(events)
      refute blob =~ "secret content here"
      refute blob =~ "viking://resources/stages/a.md"
    after
      :telemetry.detach("retrieval-stages-test")
    end
  end

  test "malformed trace context starts a new trace without rejecting" do
    :ok = AgentDb.write("viking://resources/trace/a.md", "traceable")

    assert {:ok, _} =
             AgentDb.search("traceable",
               mode: :keyword,
               trace_context: %{trace_id: "bad", span_id: "bad"}
             )

    assert {:error, {:invalid_mode, _}} =
             AgentDb.search("traceable", mode: :bogus_mode_test)
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, e, m, meta} -> collect_telemetry([{e, m, meta} | acc])
    after
      200 -> acc
    end
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
