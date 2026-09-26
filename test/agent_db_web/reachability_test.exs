defmodule AgentDbWeb.ReachabilityTest do
  use ExUnit.Case, async: false

  # The listener is off by default under test (Config.http_enabled/0 defaults to
  # false when Mix.env() == :test), so this file opts in explicitly on its own
  # port. Every other test file restarts the application from its setup block;
  # if the surface were on by default they would each bind and release a port,
  # and a collision with a running development instance would fail the
  # endpoint's start and take the suite with it.
  #
  # This test deliberately does NOT set `server: true` itself. It reads the
  # endpoint configuration evaluated at boot and overrides only the port, so
  # that removing `server: true` from config/runtime.exs makes this test fail.
  # A test that set the key itself would pass with the original defect in place.

  @port 41_099

  setup do
    original_endpoint = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])
    original_enabled = System.get_env("AGENT_DB_HTTP_ENABLED")
    original_ip = Application.get_env(:agent_db, :http_ip)

    on_exit(fn ->
      Application.put_env(:agent_db, AgentDbWeb.Endpoint, original_endpoint)

      case original_ip do
        nil -> Application.delete_env(:agent_db, :http_ip)
        ip -> Application.put_env(:agent_db, :http_ip, ip)
      end

      restore_env("AGENT_DB_HTTP_ENABLED", original_enabled)
      restart_app()
    end)

    :ok
  end

  describe "endpoint configuration" do
    test "is configured to serve" do
      endpoint_config = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

      assert Keyword.get(endpoint_config, :server) == true,
             "endpoint config must set server: true, or Phoenix starts the " <>
               "endpoint and binds nothing"

      assert Phoenix.Endpoint.Supervisor.server?(:agent_db, AgentDbWeb.Endpoint),
             "Phoenix resolved server?/2 to false, so no listener would open"
    end

    test "binds loopback by default" do
      assert AgentDb.Config.http_ip() == {127, 0, 0, 1}

      assert Keyword.get(http_config(), :ip) == {127, 0, 0, 1},
             "the unauthenticated surface must not default to every interface"
    end

    test "takes the port from a single source" do
      endpoint_config = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])
      url = Keyword.get(endpoint_config, :url, [])

      assert Keyword.get(url, :port) == Keyword.get(http_config(), :port),
             "the served port and the URL port must not disagree"
    end
  end

  describe "the listener" do
    test "answers a request on the configured port" do
      start_with_listener()

      # 200 when healthy, 503 when the store reports itself degraded because no
      # model is loaded. Both are answers; the requirement is that the request is
      # served rather than refused.
      assert {:ok, status} = get("/api/v1/health")
      assert status in [200, 503]

      # A path the router does not know must 404 rather than hang or reset,
      # which distinguishes "serving" from "port open but broken".
      assert {:ok, 404} = get("/api/v1/no-such-route-at-all")
    end

    test "is bound to loopback and not to a LAN interface" do
      start_with_listener()

      assert {:ok, _status} = get("/api/v1/health", "127.0.0.1")

      case lan_ip() do
        nil -> assert true
        ip -> assert :refused = get("/api/v1/health", ip)
      end
    end

    test "refuses connections when HTTP is disabled" do
      System.put_env("AGENT_DB_HTTP_ENABLED", "false")
      restart_app()

      assert :refused = get("/api/v1/health")
    end
  end

  describe "the pubsub server" do
    test "is started, so subscribing to the configured name does not raise" do
      assert is_pid(Process.whereis(AgentDb.PubSub)),
             "config names AgentDb.PubSub as pubsub_server but nothing started it"

      :ok = Phoenix.PubSub.subscribe(AgentDb.PubSub, "reachability-probe")
    end

    test "delivers a message to a subscriber" do
      :ok = Phoenix.PubSub.subscribe(AgentDb.PubSub, "reachability-probe")
      :ok = Phoenix.PubSub.broadcast(AgentDb.PubSub, "reachability-probe", :ping)

      assert_receive :ping, 1_000
    end
  end

  # -- helpers --

  defp start_with_listener do
    # Only the port and bind are overridden; `server:` is whatever
    # config/runtime.exs resolved, so this file stays sensitive to it.
    Application.put_env(
      :agent_db,
      AgentDbWeb.Endpoint,
      Keyword.put(
        Application.get_env(:agent_db, AgentDbWeb.Endpoint, []),
        :http,
        http_config() |> Keyword.put(:port, @port) |> Keyword.put(:ip, {127, 0, 0, 1})
      )
    )

    System.put_env("AGENT_DB_HTTP_ENABLED", "true")
    restart_app()
  end

  defp http_config do
    :agent_db
    |> Application.get_env(AgentDbWeb.Endpoint, [])
    |> Keyword.get(:http, [])
  end

  # A raw request over :gen_tcp rather than :httpc, so the test depends on no
  # extra application being started and can tell a refused connection from a
  # served one without either outcome being an exception.
  defp get(path, host \\ "127.0.0.1") do
    # :gen_tcp.connect/3 takes a charlist hostname or an IP tuple, not a binary.
    target = if is_binary(host), do: String.to_charlist(host), else: host

    # No :timeout in the connect options -- this OTP rejects it outright
    # (:badarg). The read is bounded by the :gen_tcp.recv/3 timeout instead.
    case :gen_tcp.connect(target, @port, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          request =
            "GET #{path} HTTP/1.1\r\nHost: #{host}:#{@port}\r\nConnection: close\r\n\r\n"

          :ok = :gen_tcp.send(socket, request)
          {:ok, status} = read_status(socket, "")
          {:ok, status}
        after
          :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :refused
    end
  end

  defp read_status(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n") do
          ["HTTP/1.1 " <> rest | _] ->
            [status | _] = String.split(rest, " ")
            {:ok, String.to_integer(status)}

          _ ->
            read_status(socket, acc)
        end

      {:error, _} ->
        {:ok, nil}
    end
  end

  defp lan_ip do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        addrs
        # Not every entry is a map on every OTP version.
        |> Enum.filter(&(is_map(&1) and Map.get(&1, :family) == :inet))
        |> Enum.map(& &1.addr)
        |> Enum.reject(&loopback?/1)
        |> List.first()

      _ ->
        nil
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?(_), do: false

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
