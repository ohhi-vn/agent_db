defmodule AgentDb.ML.BackendTest do
  use ExUnit.Case, async: false

  alias AgentDb.Config
  alias AgentDb.ML.ModelManager.Backend
  alias AgentDb.ML.ModelManager.Backend.Exla

  describe "Config.ml_backend/0" do
    setup do
      original = Application.get_env(:agent_db, :ml_backend)

      on_exit(fn ->
        if original == nil,
          do: Application.delete_env(:agent_db, :ml_backend),
          else: Application.put_env(:agent_db, :ml_backend, original)
      end)

      :ok
    end

    test "defaults to :auto" do
      Application.delete_env(:agent_db, :ml_backend)
      assert Config.ml_backend() == :auto
    end

    test "parses atom values" do
      Application.put_env(:agent_db, :ml_backend, :exla)
      assert Config.ml_backend() == :exla
      Application.put_env(:agent_db, :ml_backend, :emlx)
      assert Config.ml_backend() == :emlx
    end

    test "parses string env values" do
      Application.put_env(:agent_db, :ml_backend, "exla")
      assert Config.ml_backend() == :exla
      Application.put_env(:agent_db, :ml_backend, "emlx")
      assert Config.ml_backend() == :emlx
      Application.put_env(:agent_db, :ml_backend, "auto")
      assert Config.ml_backend() == :auto
    end

    test "unknown values fall back to :auto" do
      Application.put_env(:agent_db, :ml_backend, "bogus")
      assert Config.ml_backend() == :auto
    end
  end

  describe "Backend.resolve/1" do
    test "explicit values pass through" do
      assert Backend.resolve(:exla) == :exla
      assert Backend.resolve(:emlx) == :emlx
    end

    test ":auto resolves to a known backend" do
      assert Backend.resolve(:auto) in [:exla, :emlx]
    end

    test "module_for maps names to modules" do
      assert Backend.module_for(:exla) == Backend.Exla
      assert Backend.module_for(:emlx) == Backend.Emlx
    end
  end

  describe "Backend.Exla" do
    test "implements the behaviour" do
      Code.ensure_loaded!(Backend)
      Code.ensure_loaded!(Exla)
      callbacks = Backend.behaviour_info(:callbacks) |> Enum.sort()
      assert {:load_embedding, 1} in callbacks
      assert {:load_llm, 1} in callbacks
      assert {:embed, 2} in callbacks
      assert {:summarize, 3} in callbacks
      refute {:model_info, 0} in callbacks
      assert function_exported?(Exla, :load_embedding, 1)
      assert function_exported?(Exla, :load_llm, 1)
      refute function_exported?(Exla, :model_info, 0)
    end

    test "concurrent embed calls all answer" do
      # Runs leave the manager, so a caller is answered by a message rather
      # than by the process that owns the model. Several at once is the case
      # that breaks if a run's reply is tied to the wrong caller.
      config = %{
        embedding_model: "m",
        llm_model: "m",
        exla_backend: :cpu,
        llm_chat_template: "%{prompt}",
        loader: AgentDb.ML.FakeLoader
      }

      assert {:ok, model_ref} = Exla.load_embedding(config)

      results =
        1..4
        |> Enum.map(fn i -> Task.async(fn -> {i, Exla.embed(model_ref, ["text #{i}"])} end) end)
        |> Enum.map(&Task.await(&1, 5_000))

      for {_id, {:ok, [embedding]}} <- results do
        assert Nx.shape(embedding) == {2}
      end
    end

    test "embed normalizes through the fake serving" do
      config = %{
        embedding_model: "m",
        llm_model: "m",
        exla_backend: :cpu,
        llm_chat_template: "<|im_start|>user\n%{prompt}<|im_end|>\n<|im_start|>assistant\n",
        loader: AgentDb.ML.FakeLoader
      }

      assert {:ok, model_ref} = Exla.load_embedding(config)
      assert model_ref.backend == :exla
      assert {:ok, [embedding]} = Exla.embed(model_ref, ["hello"])
      assert Nx.shape(embedding) == {2}
    end

    test "summarize returns generated text" do
      config = %{
        embedding_model: "m",
        llm_model: "m",
        exla_backend: :cpu,
        llm_chat_template: "%{prompt}",
        loader: AgentDb.ML.FakeLoader
      }

      assert {:ok, model_ref} = Exla.load_llm(config)
      assert {:ok, "generated summary"} = Exla.summarize(model_ref, "hi", [])
    end
  end
end
