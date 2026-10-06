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
  def models do
    Runtime.inference().model_status()
    |> with_provider()
    |> with_queue()
  end

  # Queue depth belongs to the durable queue, not to the inference port. It is
  # added here rather than reported by the model manager because a manager that
  # loaded no model still serves a store with work queued, and a hardcoded zero
  # there would read as an idle store whatever the queue actually held.
  defp with_queue(status) when is_map(status) do
    Map.put_new(status, :queue, queue())
  end

  @doc "How much work is outstanding, by status."
  @spec queue() :: map()
  def queue do
    case Runtime.storage().queue_stats() do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  @doc """
  How far behind the queue is, and what is failing in it.

  Beyond `queue/0`'s counts: the age of the longest-waiting job, which is the
  number that says whether the workers are keeping up, and the failures that
  burned their retries. A store whose queue cannot be read reports that rather
  than reporting an empty one.
  """
  @spec queue_detail(pos_integer()) :: map()
  def queue_detail(limit \\ 20) do
    case Runtime.storage().queue_detail(limit) do
      {:ok, detail} -> detail
      {:error, _} -> %{oldest_pending_ms: nil, failed: [], available: false}
    end
  end

  @doc """
  What the store holds and how much room it takes.

  Document and directory counts, documents per top-level subtree, and the
  database and write-ahead-log sizes. These are counts, not a walk, so they
  stay cheap on a large store; a provider that cannot report a size reports
  nothing for it rather than zero.
  """
  @spec storage() :: map()
  def storage do
    case Runtime.storage().stats() do
      {:ok, stats} ->
        stats

      {:error, _} ->
        %{documents: 0, directories: 0, by_top_subtree: %{}, db_bytes: nil, wal_bytes: nil}
    end
  end

  @doc """
  How much of the store's content the vector index covers.

  An index that cannot be queried is reported unavailable, which is a different
  fact from one that holds nothing: the first means vector search cannot be
  served, the second means there is simply nothing indexed yet. The other
  indexes' coverage is added by the facade, because each index owns its roots.
  """
  @spec index_coverage() :: map()
  def index_coverage do
    case Runtime.storage().vector_index_stats() do
      {:ok, vector} -> vector
      {:error, _} -> %{available: false, vectors: nil, documents: 0}
    end
  end

  @doc """
  The size of the store's disposable read caches.

  Entry counts and bytes per table, so an operator can tell a cache that has
  grown from a store whose content has. Counted from the cache's own tables
  rather than from the runtime snapshot, whose ETS listing is bounded and can
  therefore leave these tables out on a busy node.
  """
  @spec cache() :: map()
  def cache, do: AgentDb.Cache.detailed_stats()

  # Without a model the store is still a working store: documents, search by
  # keyword, sessions and memories all work, so an unloaded embedding model is
  # a reduction rather than a failure. A remote provider holds no local model,
  # so `loaded` stays false for it; readiness is what says it can serve.
  defp embedding_ready? do
    case models() do
      %{embedding: %{loaded: true}} -> true
      %{embedding: %{state: :ready}} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # The provider kind the answering adapter reports about itself, so a
  # deployment on Ollama or OpenAI-compatible reports what actually runs rather
  # than a label read from a second configuration key that could disagree.
  # A provider that names no kind is a custom module, which is all the store
  # can honestly say about it. Existing keys are preserved; only the provider
  # annotation is added.
  defp with_provider(status) when is_map(status) do
    provider = Map.get(status, :provider, :custom)

    status
    |> Map.put(:provider, provider)
    |> Map.update(:embedding, %{provider: provider}, &Map.put_new(&1, :provider, provider))
    |> Map.update(:llm, %{provider: provider}, &Map.put_new(&1, :provider, provider))
  end
end
