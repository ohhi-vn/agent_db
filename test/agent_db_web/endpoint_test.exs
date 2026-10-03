defmodule AgentDbWeb.EndpointTest do
  @moduledoc """
  The HTTP surface's contract: what it answers, and when it is not listening.

  "Enabled" has to mean a listener that answers, not a started endpoint that
  binds nothing -- so these reach the port rather than inspecting a process.
  """
  use ExUnit.Case, async: false

  @port 41_098

  setup do
    original = Application.get_env(:agent_db, AgentDbWeb.Endpoint, [])

    originals =
      for key <- ~w(AGENT_DB_HTTP_ENABLED AGENT_DB_HTTP_AUTH AGENT_DB_HTTP_AUTH_TOKENS),
          into: %{},
          do: {key, System.get_env(key)}

    on_exit(fn ->
      Application.put_env(:agent_db, AgentDbWeb.Endpoint, original)
      for {key, value} <- originals, do: restore_env(key, value)
      :ok = restart_app()
    end)

    :ok
  end

  describe "what a client sees" do
    setup do
      start_listener()
      :ok
    end

    test "health reports the store's own checks" do
      assert {:ok, status, body} = get("/api/v1/health")

      # 200 when everything is up, 503 when it is serving without a model. Both
      # are answers; a monitor needs to tell which it got.
      assert status in [200, 503]

      assert %{"status" => verdict, "checks" => checks} = body
      assert verdict in ["ok", "degraded"]
      assert is_boolean(Map.fetch!(checks, "db"))
      assert is_boolean(Map.fetch!(checks, "models"))
    end

    test "model status is answerable and names both models" do
      assert {:ok, 200, body} = get("/api/v1/models/status")

      assert %{"embedding" => embedding, "llm" => llm} = body
      assert is_boolean(Map.fetch!(embedding, "loaded"))
      assert is_boolean(Map.fetch!(llm, "loaded"))
    end

    test "a document written over HTTP is readable over HTTP" do
      uri = "viking://resources/http/a.md"

      assert {:ok, 201, _} =
               post("/api/v1/documents", %{
                 "document" => %{"uri" => uri, "content" => "over the wire"}
               })

      assert {:ok, 200, body} = get("/api/v1/documents/#{document_path(uri)}")
      assert body["content"] == "over the wire"
    end

    test "a document that is not there is a 404, not a 500" do
      # The status is what a client acts on; the body is JSON carrying the
      # classified reason and its code.
      assert {:ok, 404, %{"error" => "not_found", "code" => "not_found"}} =
               get("/api/v1/documents/#{document_path("viking://resources/http/absent.md")}")
    end

    test "a write the store rejects is a 422 carrying the reason" do
      # An invalid URI is the store's call to make, and the reason it gives is
      # what a client needs to correct the request.
      assert {:ok, 422, %{"error" => "invalid_uri", "code" => "invalid_uri"}} =
               post("/api/v1/documents", %{
                 "document" => %{"uri" => "http://elsewhere/x", "content" => "c"}
               })
    end

    test "an unrecognized search mode is a 422 carrying its code, not a 500" do
      assert {:ok, 422, %{"error" => "invalid_mode", "code" => "invalid_mode"}} =
               post("/api/v1/search", %{"term" => "x", "mode" => "bogus"})
    end

    test "keyword search answers with results" do
      assert {:ok, 201, _} =
               post("/api/v1/documents", %{
                 "document" => %{
                   "uri" => "viking://resources/http/findme.md",
                   "content" => "distinguishable-word"
                 }
               })

      assert {:ok, 200, %{"results" => results}} =
               post("/api/v1/search", %{"term" => "distinguishable-word"})

      assert Enum.map(results, & &1["uri"]) == ["viking://resources/http/findme.md"]
    end

    test "a session is created, appended to, and read back over HTTP" do
      assert {:ok, status, %{"session_id" => id}} = post("/api/v1/sessions", %{})
      assert status in [200, 201]

      assert {:ok, 200, _} =
               post("/api/v1/sessions/#{id}/messages", %{
                 "message" => %{"role" => "user", "content" => "hi"}
               })

      assert {:ok, 200, %{"messages" => [message]}} = get("/api/v1/sessions/#{id}")
      assert message["content"] == "hi"
    end

    test "an unrouted path is a 404 rather than a hang" do
      # Distinguishes a served surface from an open port that answers nothing.
      assert {:ok, 404, _body} = get("/api/v1/no-such-route-at-all")
    end
  end

  describe "authentication" do
    test "a request with no token is refused when auth is on" do
      configure_auth("true", "secret")

      assert {:ok, 401, %{"error" => "unauthorized"}} = get("/api/v1/health")
    end

    test "a configured token is accepted" do
      configure_auth("true", "secret")

      assert {:ok, status, _body} = get("/api/v1/health", token: "secret")
      assert status in [200, 503]
    end

    test "a token that merely begins with a valid one is refused" do
      configure_auth("true", "secret")

      # Compared in full: a prefix match would accept any token starting with a
      # valid one.
      assert {:ok, 401, _body} = get("/api/v1/health", token: "secret-but-longer")
    end

    test "requests are unauthenticated when auth is off" do
      configure_auth("false", "")

      assert {:ok, status, _body} = get("/api/v1/health")
      assert status in [200, 503]
    end
  end

  describe "the listener's lifecycle" do
    test "is not opened when HTTP is disabled" do
      System.put_env("AGENT_DB_HTTP_ENABLED", "false")
      :ok = restart_app()

      # Nothing listening is the observable fact; a started endpoint that binds
      # no socket would not show here.
      assert :refused = get("/api/v1/health")
    end

    test "binds loopback rather than every interface" do
      start_listener()

      assert {:ok, status, _body} = get("/api/v1/health", host: "127.0.0.1")
      assert status in [200, 503]

      case lan_ip() do
        nil -> assert true
        ip -> assert :refused = get("/api/v1/health", host: ip)
      end
    end

    test "takes its port from a single source" do
      http = http_config()
      url = Application.get_env(:agent_db, AgentDbWeb.Endpoint, []) |> Keyword.get(:url, [])

      # Two ports that could disagree would mean the URL generation and the
      # listener had been configured independently.
      assert Keyword.fetch!(url, :port) == Keyword.fetch!(http, :port)
    end
  end

  describe "the endpoint's own configuration" do
    test "is set to serve" do
      assert Keyword.get(Application.get_env(:agent_db, AgentDbWeb.Endpoint, []), :server) == true,
             "without server: true Phoenix starts the endpoint and binds nothing"

      assert Phoenix.Endpoint.Supervisor.server?(:agent_db, AgentDbWeb.Endpoint)
    end

    test "binds loopback by default" do
      assert AgentDb.Config.http_ip() == {127, 0, 0, 1}
      assert Keyword.fetch!(http_config(), :ip) == {127, 0, 0, 1}
    end
  end

  describe "the store's pubsub" do
    test "is started whether or not HTTP is serving" do
      # The endpoint's configuration names it, so a deployment that turns HTTP
      # off must not leave anything that publishes to it stranded.
      assert is_pid(Process.whereis(AgentDb.PubSub))
      assert :ok = Phoenix.PubSub.subscribe(AgentDb.PubSub, "endpoint-test")

      :ok = Phoenix.PubSub.broadcast(AgentDb.PubSub, "endpoint-test", :ping)
      assert_receive :ping, 1_000
    end
  end

  # -- helpers --

  # The port and bind are overridden; `server:` is whatever runtime.exs
  # resolved, so a test that set it itself would pass with a defect in place.
  defp start_listener do
    Application.put_env(
      :agent_db,
      AgentDbWeb.Endpoint,
      Keyword.put(
        Application.get_env(:agent_db, AgentDbWeb.Endpoint, []),
        :http,
        Keyword.put(http_config(), :port, @port) |> Keyword.put(:ip, {127, 0, 0, 1})
      )
    )

    System.put_env("AGENT_DB_HTTP_ENABLED", "true")
    :ok = restart_app()
  end

  # A URI is one path segment, and it contains slashes and a scheme. Encoding it
  # whole leaves the slashes as path separators, so the route -- which matches a
  # single `:id` -- never matches. The separator is what has to be escaped, not
  # the rest.
  defp document_path(uri) do
    URI.encode(uri, &(&1 == "/"))
  end

  # Auth is read from the environment at boot, which is how a deployment sets
  # it, so the environment is what the test sets.
  defp configure_auth(enabled, tokens) do
    System.put_env("AGENT_DB_HTTP_AUTH", enabled)
    System.put_env("AGENT_DB_HTTP_AUTH_TOKENS", tokens)
    start_listener()
  end

  defp http_config do
    :agent_db |> Application.get_env(AgentDbWeb.Endpoint, []) |> Keyword.get(:http, [])
  end

  # A raw request over :gen_tcp rather than an HTTP client, so the test depends
  # on no extra application being started, and can tell a refused connection from
  # a served one without either outcome being an exception.
  defp get(path, opts \\ []) do
    request("GET", path, opts)
  end

  defp post(path, body, opts \\ []) do
    request("POST", path, Keyword.put(opts, :body, body))
  end

  defp request(method, path, opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    target = if is_binary(host), do: String.to_charlist(host), else: host

    case :gen_tcp.connect(target, @port, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          :ok = :gen_tcp.send(socket, request_head(method, path, opts))
          read_response(socket, "")
        after
          :gen_tcp.close(socket)
        end

      {:error, _reason} ->
        :refused
    end
  end

  defp request_head(method, path, opts) do
    payload = if body = opts[:body], do: Jason.encode!(body)

    auth =
      if token = opts[:token] do
        "authorization: Bearer #{token}\r\n"
      else
        ""
      end

    body_line =
      if payload,
        do: "content-type: application/json\r\ncontent-length: #{byte_size(payload)}\r\n",
        else: ""

    "#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n#{auth}#{body_line}\r\n#{payload || ""}"
  end

  defp read_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data
        response(acc) || read_response(socket, acc)

      {:error, _reason} ->
        {:ok, nil, %{}}
    end
  end

  # Parsed only once the head has arrived, so a body split across packets is
  # waited for rather than read short.
  defp response(acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, _body] -> response(acc, head)
      [_partial] -> nil
    end
  end

  defp response(acc, head) do
    [_version | _status_line] = String.split(head, "\r\n")
    status = head |> String.split(" ") |> Enum.at(1) |> String.to_integer()
    [head, body] = String.split(acc, "\r\n\r\n", parts: 2)

    {:ok, status, decode(declared_length(head), body)}
  end

  # The length the server said it wrote. A response with no length header has
  # been fully received by the time the connection closes, so whatever arrived
  # is the whole body.
  defp declared_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.downcase(line) do
        "content-length: " <> length -> String.to_integer(String.trim(length))
        _other -> nil
      end
    end)
  end

  defp decode(nil, body), do: decode_body(body)
  defp decode(length, body), do: decode_body(binary_part(body, 0, min(length, byte_size(body))))

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      # A body that is not JSON still says the surface answered.
      {:error, _reason} -> %{"body" => body}
    end
  end

  defp lan_ip do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        addrs
        |> Enum.filter(&(is_map(&1) and Map.get(&1, :family) == :inet))
        |> Enum.map(& &1.addr)
        |> Enum.reject(&loopback?/1)
        |> List.first()

      _other ->
        nil
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?(_other), do: false

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
