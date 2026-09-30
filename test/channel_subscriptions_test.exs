defmodule AgentDbWeb.SubscriptionChannelTest do
  use ExUnit.Case, async: false

  alias AgentDbWeb.Channel

  setup do
    :ok = AgentDb.StorageContract.Helpers.stop_workers()
    :ok
  end

  defp event(name, params, socket \\ %Phoenix.Socket{}),
    do: Channel.handle_in(name, params, socket)

  test "v1.subscribe receives versioned notifications" do
    assert {:reply, {:ok, _}, _} = event("v1.subscribe", %{"uri" => "viking://resources/chan-sub/project"})

    :ok = AgentDb.write("viking://resources/chan-sub/project/a.md", "hello")

    assert_receive {:context_changed, "viking://resources/chan-sub/project/a.md", :written, v}, 1_000
    assert is_integer(v)

    assert {:reply, {:ok, _}, _} = event("v1.unsubscribe", %{"uri" => "viking://resources/chan-sub/project"})
  end

  test "invalid subscription leaves the channel usable" do
    assert {:reply, {:error, %{reason: :invalid_uri}}, socket} =
             event("v1.subscribe", %{"uri" => "bad"})

    assert {:reply, {:ok, _}, _} =
             event("v1.subscribe", %{"uri" => "viking://resources/chan-sub/ok"}, socket)
  end

  test "progress then result ordering preserves search contract" do
    :ok = AgentDb.write("viking://resources/chan-prog/a.md", "progress hello")

    assert {:reply, {:ok, %{events: events, results: results}}, _} =
             event("v1.search_progress", %{"term" => "hello", "opts" => %{"mode" => "keyword"}})

    assert events == [
             "retrieval_started",
             "retrieval_progress",
             "resource_found",
             "memory_found",
             "skill_loaded",
             "context_assembled"
           ]

    assert is_list(results)
    assert Enum.any?(results, &(&1[:uri] == "viking://resources/chan-prog/a.md" or &1.uri == "viking://resources/chan-prog/a.md"))
  end

  test "progress failure does not break the call" do
    assert {:reply, {:ok, %{results: _}}, socket} =
             event("v1.search_progress", %{"term" => "x", "opts" => %{"mode" => "keyword"}})

    assert {:reply, {:ok, %{results: _}}, ^socket} =
             event("v1.search", %{"term" => "x", "opts" => %{"mode" => "keyword"}}, socket)
  end
end
