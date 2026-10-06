defmodule AgentDb.Adapters.Inference do
  @moduledoc false

  # The default inference provider: the local models the store loads and runs
  # itself, through Bumblebee and EXLA.
  #
  # It is a thin adapter on purpose. Model download, caching, lazy loading and
  # serving all belong to `AgentDb.ML.ModelManager` and the loader seam beneath
  # it, which is where a provider that runs a different runtime has to be
  # written instead. What this module adds is only the shape the rest of the
  # system depends on: a child to supervise, vectors as opaque bytes, and
  # failures as answers.

  @behaviour AgentDb.Core.Inference

  alias AgentDb.ML.ModelManager

  @impl true
  def child_specs(_opts), do: [{ModelManager, []}]

  @impl true
  def embed(texts) do
    case ModelManager.embed(texts) do
      # Float32 bytes rather than tensors: the store only ever persists a
      # vector, and keeping the numeric type out of the contract means a
      # provider is free to compute its vectors however it likes.
      {:ok, tensors} ->
        vectors = Enum.map(tensors, &:erlang.iolist_to_binary(Nx.to_binary(&1)))
        Enum.each(vectors, &AgentDb.Adapters.Inference.ObservedDim.observe(:local, &1))
        {:ok, vectors}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  defdelegate summarize(prompt, opts), to: ModelManager

  @impl true
  defdelegate model_status(), to: ModelManager
end
