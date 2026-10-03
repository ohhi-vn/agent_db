defmodule AgentDb.RuntimeTest do
  @moduledoc """
  Which provider answers each port, and what happens when the choice is wrong.

  Substitution is the point of the ports, so these start the whole application
  against providers that are not the defaults and check that the store works
  through them. They also check the failure it is supposed to fail at: a
  provider that cannot answer its port is a configuration error, and it must
  surface at startup rather than being quietly replaced.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Runtime
  alias AgentDb.Test.Fakes.{Inference, Storage, Transport}

  @adapters [:storage_adapter, :inference_provider, :transport_adapter]

  setup do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())

    on_exit(fn ->
      # The store is left running on the default providers, so a test that
      # selected a substitute or started a failing configuration does not leak
      # either into whatever runs next.
      delete_adapters()
      Application.delete_env(:agent_db, :fake_transport_enabled)
      Application.delete_env(:agent_db, :data_dir)
      AgentDb.Test.Script.clear(:fake_storage)
      AgentDb.Test.Script.clear(:fake_inference)
      :ok = restart_app()
    end)

    :ok
  end

  describe "the defaults" do
    test "are this project's own providers" do
      delete_adapters()

      assert Runtime.storage() == AgentDb.Adapters.SQLite
      assert Runtime.inference() == AgentDb.Adapters.Inference
      assert Runtime.transport() == AgentDb.Adapters.Phoenix
    end

    test "are what a deployment that configures nothing gets" do
      delete_adapters()

      assert :ok = Runtime.validate!()
      assert :ok = restart_app()
      assert :ok = AgentDb.write("viking://resources/defaults/a.md", "content")
      assert {:ok, "content"} = AgentDb.read("viking://resources/defaults/a.md")
    end
  end

  describe "a storage provider" do
    test "can be selected for the whole application" do
      configure(storage_adapter: Storage)

      assert :ok = Runtime.validate!()
      assert :ok = restart_app()
      assert Runtime.storage() == Storage

      # Every workflow answer now comes from the provider, with no database in
      # the picture.
      uri = "viking://resources/fake/a.md"
      assert :ok = AgentDb.write(uri, "content")
      assert {:ok, "content"} = AgentDb.read(uri)
      assert {:ok, _tree} = AgentDb.tree("viking://resources/fake", 1)
    end

    test "whose failures reach the caller unchanged" do
      configure(storage_adapter: Storage)
      assert :ok = restart_app()

      Storage.stub(:get_node, {:error, {:connection, :refused}})

      assert {:error, {:connection, :refused}} = AgentDb.read("viking://resources/fake/a.md")
    end

    test "is what background work goes through as well" do
      configure(storage_adapter: Storage, inference_provider: Inference)
      assert :ok = restart_app()

      # A worker claiming work reaches storage through the same port the
      # workflows use, so a substituted provider is not bypassed by background
      # processing.
      assert :ok = AgentDb.write("viking://resources/fake/worker.md", "content")

      job = await(fn -> Enum.find(Storage.recorded_jobs(), &(&1.kind == :embed)) end)
      assert job.payload["uri"] == "viking://resources/fake/worker.md"
    end
  end

  describe "an inference provider" do
    test "can be selected for the whole application" do
      # Both ports substituted together, because a vector search is a question
      # about a stored index as much as about the model: this is the whole
      # search path with none of the default providers in it.
      configure(storage_adapter: Storage, inference_provider: Inference)

      assert :ok = Runtime.validate!()
      assert :ok = restart_app()
      assert Runtime.inference() == Inference

      # Searchable with no model downloaded and no vector extension loaded --
      # the providers answer, and the store does not care which. The index is
      # filled by a worker, so the search waits for it rather than racing it.
      uri = "viking://resources/fake/vec.md"
      assert :ok = AgentDb.write(uri, "kubernetes scheduling")

      assert {:ok, [%{uri: ^uri} | _]} =
               await_vector_search("kubernetes scheduling", "viking://resources/fake")

      # And scoped: the same question outside that subtree reaches nothing.
      assert {:ok, []} =
               AgentDb.search("kubernetes scheduling",
                 mode: :vector,
                 scope: "viking://resources/other"
               )
    end

    test "summarizes through the selected provider, and the result is stored" do
      configure(storage_adapter: Storage, inference_provider: Inference)
      assert :ok = restart_app()

      # The provider's own summary, reached through the whole background path:
      # a write, a worker generating the layer, and a read seeing it land.
      uri = "viking://resources/fake/summary.md"
      assert :ok = AgentDb.write(uri, "a document worth summarizing")

      summary = await(fn -> generated_abstract(uri) end)
      assert summary =~ "summary of"
    end

    # The deterministic fallback is the first non-empty line, so a summary that
    # has landed is one that is not that.
    defp generated_abstract(uri) do
      case AgentDb.abstract(uri) do
        {:ok, "a document worth summarizing"} -> nil
        {:ok, abstract} -> abstract
        _other -> nil
      end
    end

    test "whose deferral is reported as loading rather than as a failure" do
      configure(inference_provider: Inference)
      assert :ok = restart_app()

      Inference.stub_embed({:error, :model_loading})

      assert {:error, :model_loading} = AgentDb.search("anything", mode: :vector)
    end

    test "is what model status reports" do
      configure(inference_provider: Inference)
      assert :ok = restart_app()

      assert %{embedding: %{model: "fake-embedder"}} = AgentDb.model_status()
    end
  end

  describe "a transport provider" do
    test "can be selected, and its children are started" do
      configure(transport_adapter: Transport)

      assert :ok = Runtime.validate!()
      assert :ok = restart_app()

      assert is_pid(Process.whereis(Transport.Probe))
    end

    test "that is disabled contributes no children" do
      configure(transport_adapter: Transport)
      Application.put_env(:agent_db, :fake_transport_enabled, false)
      assert :ok = restart_app()

      assert Process.whereis(Transport.Probe) == nil
      # The store itself is unaffected: turning off a surface is not a change
      # to what the store can do.
      assert :ok = AgentDb.write("viking://resources/quiet/a.md", "content")
    end
  end

  describe "a provider that cannot answer its port" do
    test "fails at startup rather than being replaced" do
      configure(storage_adapter: Storage.Unimplemented)

      # Substituting the default here would leave a deployment quietly serving
      # from somewhere other than where it was told to, with nothing in the logs
      # to say so.
      assert_raise ArgumentError, ~r/does not implement/, fn -> Runtime.validate!() end

      # A start fails rather than coming up on somebody else's storage.
      assert {:error, _reason} = restart_app()
      assert Process.whereis(AgentDb.Supervisor) == nil
    end

    test "names the callbacks that are missing, so the gap is findable" do
      configure(storage_adapter: Storage.Unimplemented)

      message = assert_raise(ArgumentError, fn -> Runtime.validate!() end).message

      # A provider that implements nothing is a long way from working; saying
      # which operations are missing is what makes the gap fillable.
      assert message =~ "get_node"
      assert message =~ "remove_subtree"
    end

    test "is rejected for a partial implementation too, naming what is missing" do
      configure(storage_adapter: __MODULE__.PartialStorage)

      error = assert_raise ArgumentError, fn -> Runtime.validate!() end

      # One callback supplied, the rest absent: the message says which, so the
      # gap is fillable rather than merely reported.
      refute error.message =~ "get_node/1,"
      assert error.message =~ "remove_subtree/1"
    end
  end

  describe "resolution" do
    test "is read once and consistently" do
      configure(storage_adapter: Storage)

      # Every call reaches the same provider, so two workflows cannot end up
      # reading through different ones.
      assert Runtime.storage() == Runtime.storage()
      assert Runtime.storage() == Storage
    end
  end

  # A provider that supplies most of the contract and not all of it. Partial
  # implementations are the realistic misconfiguration, so they are the one
  # worth naming precisely.
  defmodule PartialStorage do
    @moduledoc false
    # A provider that supplies some of the contract and not all of it. This is
    # the realistic misconfiguration, so it is the one worth naming precisely
    # rather than only checking the empty case.

    def child_specs(_opts), do: []
    def get_node(_uri), do: {:ok, nil}
  end

  defp configure(pairs) do
    for {key, value} <- pairs, do: Application.put_env(:agent_db, key, value)
  end

  # A vector search that waits for the index to catch up with the write, since
  # a background worker fills it.
  defp await_vector_search(term, scope) do
    await(fn ->
      case AgentDb.search(term, mode: :vector, scope: scope) do
        {:ok, []} -> nil
        found -> found
      end
    end)
  end

  # Background work is asynchronous, so a test that needs to see what a worker
  # did waits for it rather than asserting on the moment it happened to check.
  defp await(fun, attempts \\ 300)
  defp await(_fun, 0), do: flunk("condition not met in time")

  defp await(fun, attempts) do
    case fun.() do
      nil ->
        # A worker with nothing to do sleeps for seconds, so a test waiting on
        # one cannot poll in milliseconds and expect to be done.
        Process.sleep(50)
        await(fun, attempts - 1)

      value ->
        value
    end
  end

  defp delete_adapters do
    for key <- @adapters, do: Application.delete_env(:agent_db, key)
  end

  # A restart brings the application back under whatever configuration is in
  # force, so a test that selected a provider gets it in the supervision tree as
  # well as in the calls.
  #
  # A start that is expected to fail still leaves the application stopped, which
  # is what a caller of `restart_app/0` in a later test assumes; `stop/1`
  # tolerates either state rather than failing on an already-stopped one.
  defp restart_app do
    :ok = stop_app()
    Storage.reset()

    case Application.ensure_all_started(:agent_db) do
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
