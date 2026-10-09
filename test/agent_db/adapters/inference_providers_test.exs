defmodule AgentDb.InferenceProvidersTest do
  use ExUnit.Case, async: false

  alias AgentDb.Test.Fakes

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :inference_provider)
      Application.delete_env(:agent_db, :ollama_base_url)
      Application.delete_env(:agent_db, :openai_base_url)
      Application.delete_env(:agent_db, :openai_embed_model)
      Application.delete_env(:agent_db, :openai_llm_model)

      # A test that deliberately made the start fail leaves the application
      # stopped, and the next file's setup expects it running. Restarted here
      # rather than in each such test, so that this file owns the state it
      # changes.
      _ = restart_app()
    end)

    :ok
  end

  test "custom provider serves embeddings with unchanged search shape" do
    Application.put_env(:agent_db, :inference_provider, Fakes.Inference)

    assert {:ok, [vec]} = AgentDb.Runtime.inference().embed(["hello"])
    assert is_binary(vec)

    :ok = AgentDb.write("viking://resources/prov/a.md", "hello world")

    assert {:ok, results} = AgentDb.search("hello", mode: :keyword)
    assert Enum.any?(results, &(&1.uri == "viking://resources/prov/a.md"))
  end

  test "incomplete provider fails fast at startup validation" do
    Application.put_env(:agent_db, :inference_provider, Fakes.Storage.Unimplemented)

    assert_raise ArgumentError, ~r/does not implement/, fn ->
      AgentDb.Runtime.validate!()
    end
  end

  test "remote timeout does not terminate the caller" do
    Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:1")
    caller = self()

    assert {:error, {tag, _}} = AgentDb.Adapters.Inference.Ollama.embed(["hi"])
    assert tag in [:inference_timeout, :inference_failed]
    assert Process.alive?(caller)

    assert {:error, {tag2, _}} = AgentDb.Adapters.Inference.Ollama.summarize("hi", [])
    assert tag2 in [:inference_timeout, :inference_failed, :empty_summary]
    assert Process.alive?(caller)
  end

  test "openai adapter without url reports classified error and redacts keys" do
    Application.delete_env(:agent_db, :openai_base_url)
    Application.put_env(:agent_db, :openai_api_key, "sk-secret-should-never-leak")

    assert {:error, :no_provider_url} = AgentDb.Adapters.Inference.OpenAICompatible.embed(["hi"])

    # The key must not appear in the error payload.
    assert {:error, :no_provider_url} =
             AgentDb.Adapters.Inference.OpenAICompatible.summarize("hi", [])
  end

  test "one key switches both what serves and what status reports" do
    Application.put_env(:agent_db, :inference_provider, :ollama)

    # The provider that answers is derived from this one key, so there is no
    # second setting that could leave a deployment serving Ollama while its own
    # status claimed local models.
    assert AgentDb.Runtime.inference() == AgentDb.Adapters.Inference.Ollama

    status = AgentDb.model_status()
    assert status.provider == :ollama
    assert status.embedding.provider == :ollama
    assert status.llm.provider == :ollama
  end

  test "an unreachable remote provider is not reported ready" do
    Application.put_env(:agent_db, :inference_provider, :ollama)
    # Nothing is listening here, which is the state an operator most needs to
    # see truthfully: an unreachable provider reported as ready would send them
    # looking at their store instead of at the endpoint.
    Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:1")

    status = AgentDb.model_status()

    assert status.provider == :ollama
    assert status.health == :unreachable
    refute status.embedding.state == :ready
  end

  test "an unknown provider fails fast rather than serving the default" do
    Application.put_env(:agent_db, :inference_provider, :not_a_provider)

    assert_raise ArgumentError, ~r/names no known provider/, fn ->
      AgentDb.Runtime.validate!()
    end

    # The application refuses to come up rather than coming up on the default.
    assert {:error, _reason} = restart_app()
    assert Process.whereis(AgentDb.Supervisor) == nil
  end

  test "model status reports the durable queue rather than a fixed zero" do
    # Queue depth is the durable queue's to answer: a store with work enqueued
    # and a store serving from an idle queue are different facts, and a
    # hardcoded zero makes them read the same.
    AgentDb.Cache.clear()
    uri = "viking://resources/providers/queue-depth.md"
    assert :ok = AgentDb.write(uri, "body")

    status = AgentDb.model_status()

    assert is_map(status[:queue])
    assert status[:queue][:pending] >= 1
    assert status[:queue] == AgentDb.queue_stats()
  end

  # -- request shapes against recording fake servers --

  defmodule ProbeOpenAI do
    @moduledoc false
    # Records every body it receives so tests can assert on the request
    # shape, and answers like a minimal OpenAI-compatible server.
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/embeddings" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      record(:embeddings, Jason.decode!(body))

      data =
        body
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.map(fn {_text, i} -> %{"embedding" => [i * 1.0, 0.0], "index" => i} end)

      json(conn, 200, %{"data" => data})
    end

    post "/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      record(:chat, Jason.decode!(body))

      json(conn, 200, %{"choices" => [%{"message" => %{"content" => "hi"}}]})
    end

    match _ do
      send_resp(conn, 404, "no such route")
    end

    defp record(kind, decoded) do
      :ets.insert(:provider_probe, {kind, decoded})
      :ok
    end

    defp json(conn, status, payload) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end

  defmodule ProbeOllamaBatch do
    @moduledoc false
    # Answers one batched call with per-input vectors, so order preservation
    # is observable rather than asserted.
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/api/embed" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => input} = Jason.decode!(body)
      :ets.update_counter(:provider_probe, :embed_calls, {2, 1}, {:embed_calls, 0})

      vecs =
        input
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.map(fn {_text, i} -> [i * 1.0, 0.0, 0.0, 0.0] end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"embeddings" => vecs}))
    end

    match _ do
      send_resp(conn, 404, "no such route")
    end
  end

  defmodule ProbeOllamaRejectBatch do
    @moduledoc false
    # Rejects list inputs like servers that only accept one text per call,
    # so the per-text fallback is exercised rather than asserted.
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/api/embed" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => input} = Jason.decode!(body)

      if is_list(input) do
        send_resp(conn, 400, "batch not supported")
      else
        :ets.update_counter(:provider_probe, :single_calls, {2, 1}, {:single_calls, 0})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"embeddings" => [[0.5, 0.5, 0.5, 0.5]]}))
      end
    end

    match _ do
      send_resp(conn, 404, "no such route")
    end
  end

  test "openai request bodies carry the configured model" do
    table = :ets.new(:provider_probe, [:set, :public, :named_table])
    start_supervised!({Bandit, plug: ProbeOpenAI, port: 11_451})

    try do
      Application.put_env(:agent_db, :openai_base_url, "http://127.0.0.1:11451")
      Application.put_env(:agent_db, :openai_embed_model, "probe-embed-v1")
      Application.put_env(:agent_db, :openai_llm_model, "probe-llm-v1")

      assert {:ok, [_]} = AgentDb.Adapters.Inference.OpenAICompatible.embed(["hello"])
      assert {:ok, "hi"} = AgentDb.Adapters.Inference.OpenAICompatible.summarize("prompt", [])

      assert [{:embeddings, embed_body}] = :ets.lookup(table, :embeddings)
      assert embed_body["model"] == "probe-embed-v1"
      assert embed_body["input"] == ["hello"]

      assert [{:chat, chat_body}] = :ets.lookup(table, :chat)
      assert chat_body["model"] == "probe-llm-v1"
    after
      :ets.delete(table)
    end
  end

  test "ollama embeds batch inputs in one call preserving order" do
    table = :ets.new(:provider_probe, [:set, :public, :named_table])
    start_supervised!({Bandit, plug: ProbeOllamaBatch, port: 11_452})

    try do
      Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:11452")

      assert {:ok, [first, second, third]} =
               AgentDb.Adapters.Inference.Ollama.embed(["a", "b", "c"])

      # One batched call, and each position carries its own vector.
      assert [{:embed_calls, 1}] = :ets.lookup(table, :embed_calls)
      assert decode4(first) == [0.0, 0.0, 0.0, 0.0]
      assert decode4(second) == [1.0, 0.0, 0.0, 0.0]
      assert decode4(third) == [2.0, 0.0, 0.0, 0.0]
    after
      :ets.delete(table)
    end
  end

  test "ollama falls back to per-text calls when the server rejects a batch" do
    table = :ets.new(:provider_probe, [:set, :public, :named_table])
    start_supervised!({Bandit, plug: ProbeOllamaRejectBatch, port: 11_453})

    try do
      Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:11453")

      assert {:ok, [_, _]} = AgentDb.Adapters.Inference.Ollama.embed(["x", "y"])
      assert [{:single_calls, 2}] = :ets.lookup(table, :single_calls)
    after
      :ets.delete(table)
    end
  end

  defp decode4(<<a::float-32, b::float-32, c::float-32, d::float-32>>), do: [a, b, c, d]

  defmodule ProbeOllamaHealthy do
    @moduledoc false
    # Reachable remote: tags answer, so the provider reports ready.
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/api/tags" do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{models: []}))
    end

    match _ do
      send_resp(conn, 404, "no such route")
    end
  end

  test "a reachable remote counts as healthy, an unreachable one as degraded" do
    start_supervised!({Bandit, plug: ProbeOllamaHealthy, port: 11_454})

    Application.put_env(:agent_db, :inference_provider, :ollama)
    Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:11454")

    assert %{status: "ok", checks: %{db: true, models: true}} = AgentDb.health_check()

    Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:1")

    assert %{status: "degraded", checks: %{db: true, models: false}} = AgentDb.health_check()
  end

  test "embedding dims are last-observed, unknown before the first embed" do
    alias AgentDb.Adapters.Inference.ObservedDim

    ObservedDim.reset()

    assert ObservedDim.get(:local) == :unknown
    assert ObservedDim.get(:ollama) == :unknown
    assert ObservedDim.get(:openai_compatible) == :unknown

    assert AgentDb.Adapters.Inference.Ollama.model_status().embedding.dim == :unknown

    table = :ets.new(:provider_probe, [:set, :public, :named_table])
    start_supervised!({Bandit, plug: ProbeOllamaBatch, port: 11_455})

    try do
      Application.put_env(:agent_db, :ollama_base_url, "http://127.0.0.1:11455")

      assert {:ok, [_]} = AgentDb.Adapters.Inference.Ollama.embed(["hi"])

      assert ObservedDim.get(:ollama) == 4
      assert AgentDb.Adapters.Inference.Ollama.model_status().embedding.dim == 4
      assert ObservedDim.get(:local) == :unknown
      assert ObservedDim.get(:openai_compatible) == :unknown
    after
      :ets.delete(table)
    end
  end

  # A restart brings the application back under whatever configuration is in
  # force. A test that deliberately made the start fail leaves it stopped, so
  # `stop/1` tolerates either state and the result is returned rather than
  # matched, letting those tests assert on the failure.
  defp restart_app do
    with :ok <- stop_app() do
      Application.ensure_all_started(:agent_db)
    end
    |> case do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_app do
    case Application.stop(:agent_db) do
      :ok -> :ok
      {:error, {:not_started, :agent_db}} -> :ok
    end
  end
end
