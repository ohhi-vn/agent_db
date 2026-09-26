defmodule AgentDb.ML.BumblebeeLoaderTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.{BumblebeeLoader, FakeBumblebee, FakeCallLog}

  @repo {:hf, "sentence-transformers/all-MiniLM-L6-v2"}

  setup do
    :ok = FakeCallLog.start()
    :ok
  end

  describe "load_model/3" do
    test "calls the library once, with a repository" do
      assert {:ok, %{model: _, spec: _}} =
               BumblebeeLoader.load_model(@repo, [backend: :cpu], FakeBumblebee)

      assert [{@repo, []}] = FakeCallLog.entries(:load_model)
    end

    test "omits the backend option for :cpu rather than passing the atom" do
      # Bumblebee reads a bare atom as a backend *module*, so :cpu would be
      # resolved as a module named :cpu and raise.
      assert {:ok, _} = BumblebeeLoader.load_model(@repo, [backend: :cpu], FakeBumblebee)

      assert [{@repo, opts}] = FakeCallLog.entries(:load_model)
      refute Keyword.has_key?(opts, :backend)
    end

    test "defaults to the Nx backend when no backend is configured" do
      assert {:ok, _} = BumblebeeLoader.load_model(@repo, [], FakeBumblebee)

      assert [{@repo, opts}] = FakeCallLog.entries(:load_model)
      refute Keyword.has_key?(opts, :backend)
    end

    test "an accelerator without a configured EXLA client does not reach the library" do
      # No `config :exla, clients` is set up here, so resolving :cuda fails
      # before the library is called. It fails by exiting, which is contained
      # one level up in ModelManager; what matters here is that the library is
      # never asked to load onto a bogus backend.
      result =
        try do
          BumblebeeLoader.load_model(@repo, [backend: :cuda], FakeBumblebee)
        catch
          :exit, _ -> :exited
        end

      assert result == :exited
      assert FakeCallLog.entries(:load_model) == []
    end

    test "returns the loaded model rather than feeding it back in" do
      # A second call with the already-loaded map used to raise ArgumentError,
      # because Bumblebee accepts only {:hf, id} or {:local, dir} as a
      # repository. Exactly one call must reach the library.
      assert {:ok, loaded} = BumblebeeLoader.load_model(@repo, [], FakeBumblebee)
      assert is_map(loaded)
      assert [_] = FakeCallLog.entries(:load_model)
    end
  end

  describe "load_tokenizer/2" do
    test "calls the library once, with a repository" do
      assert {:ok, _} = BumblebeeLoader.load_tokenizer(@repo, FakeBumblebee)
      assert [{@repo, _}] = FakeCallLog.entries(:load_tokenizer)
    end
  end

  describe "backend_spec/1" do
    test ":cpu means the default backend" do
      assert BumblebeeLoader.backend_spec(:cpu) == :none
    end

    test "an accelerator resolves to an EXLA client, or fails loudly" do
      # Either it resolves (EXLA clients configured) or it raises because none
      # are -- what it must not do is return something Bumblebee would read as
      # a module named :cuda.
      result =
        try do
          BumblebeeLoader.backend_spec(:cuda)
        rescue
          error -> {:raised, error.__struct__}
        catch
          :exit, _ -> :exited
        end

      case result do
        {EXLA.Backend, opts} -> assert Keyword.has_key?(opts, :client)
        {:raised, _} -> :ok
        :exited -> :ok
      end
    end
  end

  describe "serving/1" do
    test "maps roles to Bumblebee serving modules" do
      assert BumblebeeLoader.serving(:embedding) == Bumblebee.Text.TextEmbedding
      assert BumblebeeLoader.serving(:llm) == Bumblebee.Text.Generation
    end
  end
end
