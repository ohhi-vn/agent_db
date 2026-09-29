defmodule AgentDb.Core.ContractsTest do
  @moduledoc """
  The three ports the rest of the system is arranged around.

  These assertions are about the shape of the contracts rather than the
  behaviour of the default adapters: which operations a provider must supply,
  and that a provider can be written against them without reaching for the
  infrastructure the default one happens to use.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Test.Fakes.{Inference, Storage, Transport}
  alias AgentDb.Test.Script

  setup do
    on_exit(fn ->
      Script.clear(:fake_storage)
      Script.clear(:fake_inference)
    end)

    :ok
  end

  describe "the storage port" do
    test "requires an operation for every durable store and the invariants that hold them together" do
      callbacks = callbacks(AgentDb.Core.Storage)

      for operation <- [
            :child_specs,
            :get_node,
            :put_document,
            :list_children,
            :remove_subtree,
            :replace_skill,
            :put_layer_result,
            :put_embedding_result,
            :search_keyword,
            :search_vector,
            :create_session,
            :append_message,
            :get_session,
            :commit_hash,
            :put_commit,
            :put_memory,
            :recall_memories,
            :memory_recorded?,
            :enqueue_job,
            :cancel_jobs,
            :count_jobs,
            :dequeue_job,
            :complete_job,
            :fail_job,
            :defer_job,
            :reset_running_jobs,
            :queue_stats,
            :healthy?
          ] do
        assert Enum.any?(callbacks, fn {name, _arity} -> name == operation end),
               "#{operation} is missing from the storage contract, so no provider is required to supply it"
      end
    end

    test "exposes no raw database access" do
      # A connection- or statement-shaped callback would let SQL leak into the
      # workflows, which is the coupling this port exists to remove.
      raw =
        Enum.filter(callbacks(AgentDb.Core.Storage), fn {name, _arity} ->
          name in [:conn, :read, :write, :exec, :query, :query_one, :transaction, :prepare]
        end)

      assert raw == [],
             "the storage contract must stay in whole operations: #{inspect(raw)}"
    end

    test "a provider can be written against it" do
      assert {:ok, _node} = Storage.get_node("viking://resources/a.md")
      assert :ok = Storage.put_document("viking://resources/a.md", "body", [])

      Storage.stub(:list_children, {:ok, ["a.md"]})
      assert {:ok, ["a.md"]} = Storage.list_children("viking://resources")

      assert :ok = Storage.remove_subtree("viking://resources")
    end

    test "a provider's failures reach the caller unchanged" do
      Storage.stub(:list_children, {:error, :not_found})
      assert {:error, :not_found} = Storage.list_children("viking://resources")

      Storage.stub(:remove_subtree, {:error, :is_root})
      assert {:error, :is_root} = Storage.remove_subtree("viking://")
    end

    test "a node is a plain value rather than an adapter's own struct" do
      Storage.set_stub_node(%{
        uri: "",
        parent_uri: nil,
        name: "a.md",
        kind: :doc,
        content: "body",
        abstract: nil,
        overview: nil
      })

      assert {:ok, node} = Storage.get_node("viking://resources/a.md")

      # A plain map with the port's own fields: a struct would tie a caller to
      # whichever provider produced it.
      assert is_map(node) and not is_struct(node)
      assert %{uri: "viking://resources/a.md", kind: :doc, content: "body"} = node
    end
  end

  describe "the inference port" do
    test "asks for embedding and summarization separately" do
      callbacks = callbacks(AgentDb.Core.Inference)

      assert Enum.any?(callbacks, &match?({:embed, 1}, &1))
      assert Enum.any?(callbacks, &match?({:summarize, 2}, &1))
      assert Enum.any?(callbacks, &match?({:model_status, 0}, &1))
    end

    test "a provider returns comparable vectors without loading anything" do
      assert {:ok, [first, again, other]} = Inference.embed(["alpha", "alpha", "beta"])

      assert first == again,
             "the same text must embed identically, or a stored index loses its meaning"

      refute first == other
      assert byte_size(first) == Inference.dim() * 4, "a vector is float32 per dimension"
    end

    test "a provider reports a loading model as loading rather than as a failure" do
      Inference.stub_embed({:error, :model_loading})
      assert {:error, :model_loading} = Inference.embed(["alpha"])

      # The two are told apart by shape, which is what a caller acts on: one is
      # safe to repeat, the other is not.
      Inference.stub_embed({:error, {:model_not_found, "/cache/model.safetensors"}})
      assert {:error, {:model_not_found, _}} = Inference.embed(["alpha"])
    end

    test "a provider summarises and refuses to report an empty answer as one" do
      assert {:ok, "summary of a document"} = Inference.summarize("a document", max_tokens: 256)

      Inference.stub_summarize({:error, {:empty_summary, :no_answer}})
      assert {:error, {:empty_summary, :no_answer}} = Inference.summarize("a document", [])
    end

    test "a provider answers what it is doing without waiting for a model" do
      assert %{embedding: %{state: :ready}, llm: %{state: :ready}} = Inference.model_status()
    end
  end

  describe "the transport port" do
    test "decides for itself whether it belongs in the deployment" do
      assert Transport.enabled?() == true

      Application.put_env(:agent_db, :fake_transport_enabled, false)
      on_exit(fn -> Application.delete_env(:agent_db, :fake_transport_enabled) end)

      refute Transport.enabled?()
    end

    test "supplies its own children, so it can be assembled without Phoenix" do
      assert [{AgentDb.Test.Fakes.Transport.Probe, []}] = Transport.child_specs(path: "unused")
    end
  end

  defp callbacks(behaviour) do
    Code.ensure_loaded!(behaviour)
    behaviour.behaviour_info(:callbacks)
  end
end
