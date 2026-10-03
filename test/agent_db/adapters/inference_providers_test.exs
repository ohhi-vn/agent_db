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
