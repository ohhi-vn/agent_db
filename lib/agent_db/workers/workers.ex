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
    # Through the boundary: an index that raises or refuses under load must
    # reach this worker as a classification it can defer on, not as an exit
    # that takes the worker down with it.
    Runtime.vector_put(job_id, uri, embedding)
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

  # A layer's budget, and how the worker holds a provider to it. An abstract is
  # one sentence because that is what makes it a decision input; an overview is
  # five because that is what keeps scanning it cheap no matter how the provider
  # answered.
  @budgets [abstract: 1, overview: 5]

  @impl JobWorker.Handler
  def kinds, do: [:summarize_abstract, :summarize_overview]

  @layer_kinds [:summarize_abstract, :summarize_overview]

  # A summary job says which layer it is for, so the worker never has to
  # remember what it was working on across a deferral.
  @impl JobWorker.Handler
  def generate(%{kind: kind, payload: payload}) when kind in @layer_kinds do
    content = payload["content"]
    # A payload written before the store carried an identity reads as having
    # none, which is the same prompt it would have been given then.
    identity = payload["identity"]

    with {:ok, summary} <-
           Runtime.inference().summarize(prompt(layer(kind), content, identity),
             max_tokens: @max_tokens
           ) do
      {:ok, trim(layer(kind), summary)}
    end
  end

  @doc """
  Holds a generated layer to its sentence budget.

  The prompt asks for the budget; this is what enforces it. A provider that
  ignores the instruction would otherwise store an unbounded layer, and an
  abstract that is a paragraph is a second overview rather than a one-line
  decision input.

  Public for the same reason `prompt/3` is: what a provider is held to is a
  contract, and a contract that cannot be asserted is not one. The backends
  have already stripped any reasoning by the time the answer gets here, so what
  survives the trim is real answer text and never reasoning.

  A provider that answered within budget is returned exactly as it answered.
  Only a trim that would leave nothing returns the answer whole -- the
  empty-summary contract is about a provider that produced nothing, not about a
  bound.
  """
  @spec trim(:abstract | :overview, String.t()) :: String.t()
  def trim(layer, summary) do
    case sentences(summary) do
      nil ->
        summary

      sentences ->
        allowed = budget(layer)

        if length(sentences) <= allowed do
          summary
        else
          # The divider after the last kept sentence goes with it: a stored
          # layer is read, not scanned, and a trailing space is noise.
          sentences |> Enum.take(allowed) |> Enum.join("") |> String.trim_trailing()
        end
    end
  end

  defp budget(:abstract), do: Keyword.fetch!(@budgets, :abstract)
  defp budget(:overview), do: Keyword.fetch!(@budgets, :overview)

  # A sentence ends at `.`, `!`, or `?` followed by whitespace or the end of
  # input, or at a newline. Anything else is one run, because splitting on a
  # period mid-abbreviation would cut a real sentence in half.
  defp sentences(summary) do
    case Regex.split(~r/(?<=[.!?])\s+|\n+/u, summary, include_captures: true, trim: true) do
      [] -> nil
      parts -> join_captures(parts)
    end
  end

  defp join_captures(parts) do
    parts
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [text, divider] -> text <> divider
      [text] -> text
    end)
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

  Three shapes, because the three things a prompt can be given do different
  work. An abstract is the document's core point in a sentence; an overview is a
  structured scan of it. A document with a frontmatter identity is given it, so
  a layer states what the document is *for* rather than summarizing metadata --
  and the identity is context to write from, never text to summarize.
  """
  @spec prompt(:abstract | :overview, String.t(), String.t() | nil) :: String.t()
  def prompt(:abstract, content, nil) do
    """
    Summarize the following text in ONE sentence capturing the core point.
    Prefer the terms that distinguish this document from others -- its subject,
    identifiers, decisions, or scope -- over wording that would fit any
    document:

    #{content}

    Abstract:
    """
  end

  def prompt(:abstract, content, identity) do
    """
    Summarize the following text in ONE sentence capturing the core point.
    Prefer the terms that distinguish this document from others -- its subject,
    identifiers, decisions, or scope -- over wording that would fit any
    document.

    This document is: #{identity}

    #{content}

    Abstract:
    """
  end

  def prompt(:overview, content, nil) do
    """
    Provide a concise structured overview (at most 5 sentences) of the following
    text, covering its key points for quick scanning. Prefer the terms that
    distinguish this document from others -- its subject, identifiers, decisions,
    or scope -- over wording that would fit any document:

    #{content}

    Overview:
    """
  end

  def prompt(:overview, content, identity) do
    """
    Provide a concise structured overview (at most 5 sentences) of the following
    text, covering its key points for quick scanning. Prefer the terms that
    distinguish this document from others -- its subject, identifiers, decisions,
    or scope -- over wording that would fit any document.

    This document is: #{identity}

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

defmodule AgentDb.Workers.VectorReclaim do
  @moduledoc false
  # Reclaims index rows the node store no longer names.
  #
  # The vector index is derived, so drift is a cost rather than a defect: rows
  # for removed URIs are already invisible to search, because the read path
  # joins them away. What they still do is occupy the index, and grow without
  # anyone being told -- which is precisely how the orphan leak in
  # `harden-node-removal` stayed silent. Boot-time reclamation closes it once
  # at startup; this worker closes it while the application runs.
  #
  # It is a durable job rather than a timer, for the reason `defer_job/2` exists:
  # an idle store costs one count per cadence instead of a full scan, a stalled
  # reclamation is visible in `queue_detail/1` rather than being invisible
  # scheduling, and a restart does not lose the scheduled work. A worker that
  # cannot reach the index defers, so the job's attempt budget is spent on work
  # that can actually fail rather than on a slow pass.

  @behaviour AgentDb.Workers.JobWorker.Handler

  alias AgentDb.Config
  alias AgentDb.Runtime
  alias AgentDb.Workers.JobWorker

  @impl JobWorker.Handler
  def kinds, do: [:reclaim_vector_index]

  # Nothing to generate: the work is entirely on the write side, and the count
  # is what decides between reclaiming and waiting. Reporting it through
  # `generate/1` rather than duplicating the query keeps one definition of what
  # drift is.
  @impl JobWorker.Handler
  def generate(%{payload: _payload}) do
    case Runtime.vector_reclaimable() do
      {:ok, 0} -> {:ok, :clean}
      {:ok, count} -> {:ok, {:reclaim, count}}
      {:error, _} = err -> err
    end
  end

  @impl JobWorker.Handler
  def store(%{id: job_id, payload: payload}, :clean) do
    # Nothing to do, so the job comes back later without spending an attempt.
    # This is the whole reason the cadence is a deferral rather than a rescan.
    case Runtime.storage().defer_job(job_id, cadence_ms(payload)) do
      :ok -> {:ok, :deferred}
      {:error, _} = err -> err
    end
  end

  def store(%{id: job_id, payload: payload}, {:reclaim, _count}) do
    case Runtime.storage().reclaim_vector_index() do
      :ok ->
        _ = Runtime.storage().defer_job(job_id, cadence_ms(payload))
        {:ok, :stored}

      {:error, _} = err ->
        err
    end
  end

  # The ceiling on a retry's delay. A job rescheduled after a failure waits at
  # most this long, whatever the configured cadence, so a store with a very long
  # cadence does not also take very long to notice that reclamation is working
  # again.
  @max_retry_delay_ms 10_000

  # Where the job came from decides how long it waits. A failure reschedules
  # sooner, because the thing that failed is still failing; the steady state
  # waits out the cadence, because running the count more often than drift
  # accumulates is work nobody asked for.
  defp cadence_ms(%{"_retry" => true}),
    do: min(Config.vector_reclaim_cadence_ms(), @max_retry_delay_ms)

  defp cadence_ms(_payload), do: Config.vector_reclaim_cadence_ms()

  @doc "The name this worker is registered under."
  @spec registration() :: String.t()
  def registration, do: "vector_reclaim_worker"

  @doc false
  def child_spec(opts) do
    worker_id = Keyword.get(opts, :worker_id, registration())

    JobWorker.child_spec(Keyword.merge(opts, handler: __MODULE__, worker_id: worker_id))
  end
end
