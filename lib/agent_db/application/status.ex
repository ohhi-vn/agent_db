defmodule AgentDb.Application.Status do
  @moduledoc false

  # What the store can report about itself.

  alias AgentDb.Runtime

  @doc """
  Whether the store and its models are usable.

  Reported per-check rather than as one verdict, so a caller can tell an empty
  but working store from one that has lost its database, and a store serving
  without a model from one that cannot serve at all.
  """
  @spec health() :: %{status: String.t(), checks: %{db: boolean(), models: boolean()}}
  def health do
    db = Runtime.storage().healthy?()
    models = embedding_ready?()

    %{
      status: if(db and models, do: "ok", else: "degraded"),
      checks: %{db: db, models: models}
    }
  end

  @doc "How the store's models are doing, including a load in progress."
  @spec models() :: map()
  def models, do: Runtime.inference().model_status()

  @doc "How much work is outstanding, by status."
  @spec queue() :: map()
  def queue do
    case Runtime.storage().queue_stats() do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  # Without a model the store is still a working store: documents, search by
  # keyword, sessions and memories all work, so an unloaded embedding model is
  # a reduction rather than a failure.
  defp embedding_ready? do
    %{embedding: %{loaded: loaded}} = models()
    loaded == true
  end
end
