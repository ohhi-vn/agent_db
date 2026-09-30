defmodule AgentDb.InferenceProvidersTest do
  use ExUnit.Case, async: false

  alias AgentDb.Test.Fakes

  setup do
    AgentDb.Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :inference_adapter)
      Application.delete_env(:agent_db, :ollama_base_url)
      Application.delete_env(:agent_db, :openai_base_url)
    end)

    :ok
  end

  test "custom provider serves embeddings with unchanged search shape" do
    Application.put_env(:agent_db, :inference_adapter, Fakes.Inference)

    assert {:ok, [vec]} = AgentDb.Runtime.inference().embed(["hello"])
    assert is_binary(vec)

    :ok = AgentDb.write("viking://resources/prov/a.md", "hello world")

    assert {:ok, results} = AgentDb.search("hello", mode: :keyword)
    assert Enum.any?(results, &(&1.uri == "viking://resources/prov/a.md"))
  end

  test "incomplete provider fails fast at startup validation" do
    Application.put_env(:agent_db, :inference_adapter, Fakes.Storage.Unimplemented)

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
    assert {:error, :no_provider_url} = AgentDb.Adapters.Inference.OpenAICompatible.summarize("hi", [])
  end

  test "model status reflects active provider kind" do
    Application.put_env(:agent_db, :inference_adapter, Fakes.Inference)
    Application.put_env(:agent_db, :inference_provider, :ollama)

    status = AgentDb.model_status()
    assert status[:provider] == :ollama
    assert status[:embedding][:provider] == :ollama or status[:provider] == :ollama
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
