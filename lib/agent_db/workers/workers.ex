defmodule AgentDb.Workers.Embedding do
  @moduledoc false
  # Turns a document into the vector that makes it findable by meaning.
  #
  # An embedding is a reachability concern rather than a compression one: it is
  # what lets a document be found by what it is about instead of by the words it
  # happens to contain.

  @behaviour AgentDb.Workers.JobWorker.Handler

  alias AgentDb.Runtime
  alias AgentDb.Workers.JobWorker

  @impl JobWorker.Handler
  def kinds, do: [:embed]

  @impl JobWorker.Handler
  def generate(%{payload: %{"content" => content}}) do
    case Runtime.inference().embed([content]) do
      {:ok, [embedding | _]} -> {:ok, embedding}
      {:ok, []} -> {:error, :no_embedding}
      {:error, _} = err -> err
    end
  end

  @impl JobWorker.Handler
  def store(%{id: job_id, payload: %{"uri" => uri}}, embedding) do
    Runtime.storage().put_embedding_result(job_id, uri, embedding)
  end

  @doc "The name this worker is registered under."
  @spec registration() :: String.t()
  def registration, do: "embedding_worker_1"

  @spec registration(pos_integer()) :: String.t()
  def registration(n) when is_integer(n) and n > 0, do: "embedding_worker_#{n}"

  @doc false
  def child_spec(opts) do
    worker_id = Keyword.get(opts, :worker_id, registration())

    JobWorker.child_spec(Keyword.merge(opts, handler: __MODULE__, worker_id: worker_id))
  end
end

defmodule AgentDb.Workers.Summarization do
  @moduledoc false
  # Turns a document into the L0 or L1 layer that compresses it.
  #
  # The prompt is the summarization model's own rather than the store's: what a
  # summary should say is a property of the model being asked, which is why it
  # lives beside the worker that asks rather than in the write path. Summaries
  # are never generated for a memory, which records an atomic fact its value
  # already states.

  @behaviour AgentDb.Workers.JobWorker.Handler

  alias AgentDb.Runtime
  alias AgentDb.Workers.JobWorker

  @max_tokens 256

  @impl JobWorker.Handler
  def kinds, do: [:summarize_abstract, :summarize_overview]

  @layer_kinds [:summarize_abstract, :summarize_overview]

  # A summary job says which layer it is for, so the worker never has to
  # remember what it was working on across a deferral.
  @impl JobWorker.Handler
  def generate(%{kind: kind, payload: %{"content" => content}}) when kind in @layer_kinds do
    Runtime.inference().summarize(prompt(layer(kind), content), max_tokens: @max_tokens)
  end

  @impl JobWorker.Handler
  def store(%{id: job_id, kind: kind, payload: %{"uri" => uri}}, summary)
      when kind in @layer_kinds do
    Runtime.storage().put_layer_result(job_id, uri, layer(kind), summary)
  end

  defp layer(:summarize_abstract), do: :abstract
  defp layer(:summarize_overview), do: :overview

  @doc """
  The prompt for a layer.

  Two shapes, because the two layers do different work: an abstract is the
  document's core point in a sentence, an overview is a structured scan of it.
  """
  @spec prompt(:abstract | :overview, String.t()) :: String.t()
  def prompt(:abstract, content) do
    """
    Summarize the following text in ONE sentence capturing the core point:

    #{content}

    Abstract:
    """
  end

  def prompt(:overview, content) do
    """
    Provide a concise structured overview (3-5 sentences) of the following text:

    #{content}

    Overview:
    """
  end

  @doc "The name this worker is registered under."
  @spec registration() :: String.t()
  def registration, do: "summarization_worker_1"

  @spec registration(pos_integer()) :: String.t()
  def registration(n) when is_integer(n) and n > 0, do: "summarization_worker_#{n}"

  @doc false
  def child_spec(opts) do
    worker_id = Keyword.get(opts, :worker_id, registration())

    JobWorker.child_spec(Keyword.merge(opts, handler: __MODULE__, worker_id: worker_id))
  end
end
