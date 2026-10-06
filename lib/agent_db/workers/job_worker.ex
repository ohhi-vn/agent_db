defmodule AgentDb.Workers.JobWorker do
  @moduledoc false

  # The shape both background workers share: claim a job, produce a result
  # through the inference port, hand it to the storage port, and report the
  # outcome to the queue.
  #
  # Which jobs a worker claims and what it does with the result are not shared,
  # so a handler module supplies those and this module owns everything else:
  # the polling loop, the three outcomes, and the logging. Two workers running
  # the same loop with different handlers is the whole of the difference
  # between embedding a document and summarizing it.

  use GenServer

  alias AgentDb.Observability
  alias AgentDb.Runtime

  require Logger

  defmodule Handler do
    @moduledoc false
    # What one kind of background work is: which jobs it claims, and what it
    # does with them.

    @doc "The job kinds this handler claims. A worker never claims a job it cannot run."
    @callback kinds() :: [atom()]

    @doc """
    Produces the result for a claimed job.

    Returns `{:ok, result}` to store it, `{:error, :model_loading}` when a
    model is still loading, and any other `{:error, reason}` to fail the job.
    """
    @callback generate(AgentDb.Core.Storage.job()) :: {:ok, term()} | {:error, term()}

    @doc "Stores the result for a job, or reports that its node is gone."
    @callback store(AgentDb.Core.Storage.job(), term()) ::
                {:ok, :stored | :discarded} | {:error, term()}
  end

  @doc "Starts a worker that runs the work `handler` describes."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    worker_id = Keyword.fetch!(opts, :worker_id)
    GenServer.start_link(__MODULE__, {handler, worker_id}, name: via(worker_id))
  end

  @doc "Where a worker of this id is registered."
  @spec via(String.t()) :: {:via, :global, String.t()}
  def via(worker_id), do: {:via, :global, worker_id}

  @doc false
  def child_spec(opts) do
    handler = Keyword.fetch!(opts, :handler)
    worker_id = Keyword.fetch!(opts, :worker_id)

    %{
      id: {handler, worker_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      # A worker holds a claimed job and nothing else, so a shutdown that
      # waited for it could block on a model that is not answering. The job is
      # recovered by the next boot.
      shutdown: 5_000
    }
  end

  @impl GenServer
  def init({handler, worker_id}) do
    # Asked for, not assumed: a worker that started without looking for work
    # would sit idle until something else happened to wake it.
    {:ok, %{handler: handler, worker_id: worker_id, failures: 0}, {:continue, :work}}
  end

  @impl GenServer
  def handle_continue(:work, state) do
    {:noreply, work(state)}
  end

  @impl GenServer
  def handle_info(:process_next, state) do
    {:noreply, work(state)}
  end

  # An idle worker costs one wakeup every few seconds rather than one per job.
  @idle_poll_ms 5_000
  @max_backoff_ms 60_000

  # How long to wait before looking again at a model that is still loading.
  @model_loading_delay_ms 1_000

  # A claim is followed immediately by another: work often arrives in batches
  # already queued, so idling between them would only add latency.
  defp work(%{handler: handler, worker_id: worker_id, failures: failures} = state) do
    result =
      try do
        case Runtime.storage().dequeue_job(handler.kinds()) do
          {:ok, job} ->
            :ok = process(Runtime.storage(), handler, job)
            send(self(), :process_next)
            %{state | failures: 0}

          {:error, :empty} ->
            Process.send_after(self(), :process_next, @idle_poll_ms)
            %{state | failures: 0}

          {:error, reason} ->
            Logger.error("#{worker_id} dequeue error: #{inspect(reason)}")
            Process.send_after(self(), :process_next, backoff(failures))
            %{state | failures: failures + 1}
        end
      rescue
        error ->
          Logger.error("#{worker_id} worker crashed, recovered: #{inspect(error)}")
          Process.send_after(self(), :process_next, backoff(failures))
          %{state | failures: failures + 1}
      catch
        kind, reason ->
          Logger.error("#{worker_id} worker caught #{inspect(kind)}: #{inspect(reason)}")
          Process.send_after(self(), :process_next, backoff(failures))
          %{state | failures: failures + 1}
      end

    :ok = :ok
    result
  end

  defp backoff(failures) do
    min(@max_backoff_ms, @idle_poll_ms * Integer.pow(2, min(failures, 3)))
  end

  # The three outcomes are kept apart because the queue treats them differently.
  # A model still loading is not a failure: the job is rescheduled without
  # spending an attempt, so a slow first download cannot exhaust the budget of
  # work that has not had its chance yet. A failure is recorded. A result goes
  # to storage, which decides whether its node is still there to receive it.
  defp process(storage, handler, job) do
    queue_wait = queue_wait_ms(job)
    start = System.monotonic_time(:millisecond)

    Observability.with_span("agent_db.job", %{kind: job.kind}, fn ->
      outcome =
        try do
          if job.kind in handler.kinds() do
            case handler.generate(job) do
              {:ok, result} -> store(storage, handler, job, result)
              {:error, :model_loading} -> defer(storage, job.id)
              {:error, reason} -> fail(storage, job.id, reason)
              other -> fail(storage, job.id, {:invalid_job_result, other})
            end
          else
            fail(storage, job.id, {:unknown_job_kind, job.kind})
          end
        rescue
          error -> fail(storage, job.id, {:worker_crash, error.__struct__})
        catch
          kind, reason -> fail(storage, job.id, {:worker_catch, kind, reason})
        end

      execution = System.monotonic_time(:millisecond) - start
      Observability.emit_job(job.kind, outcome, queue_wait, execution)

      Observability.log(:info,
        component: :worker,
        kind: job.kind,
        outcome: outcome,
        job_id: job.id,
        trace_id: trace_id(job)
      )

      :ok
    end)
  end

  defp queue_wait_ms(%{queued_at: queued, claimed_at: claimed})
       when is_integer(queued) and is_integer(claimed),
       do: max(claimed - queued, 0)

  defp queue_wait_ms(_), do: 0

  defp trace_id(%{payload: %{"_trace" => %{"trace_id" => trace_id}}}), do: trace_id
  defp trace_id(_), do: nil

  defp store(storage, handler, job, result) do
    outcome =
      try do
        handler.store(job, result)
      rescue
        error -> {:error, {:store_crash, error.__struct__}}
      catch
        kind, reason -> {:error, {:store_catch, kind, reason}}
      end

    case outcome do
      {:ok, :stored} ->
        # A read may already have cached the deterministic fallback, and a
        # summary that lands behind it would never be seen. Whoever writes has
        # to drop what it made stale.
        AgentDb.Cache.invalidate_write(job.payload["uri"])
        :stored

      # The node was removed while the model was running. The job is already
      # done; its result is simply not wanted.
      {:ok, :discarded} ->
        Observability.log(:info,
          component: :worker,
          kind: job.kind,
          outcome: :discarded,
          job_id: job.id,
          trace_id: trace_id(job)
        )

        :discarded

      {:error, reason} ->
        fail(storage, job.id, reason)
    end
  end

  defp defer(storage, job_id) do
    case storage.defer_job(job_id, @model_loading_delay_ms) do
      :ok ->
        :deferred

      {:error, reason} ->
        Observability.log(:error,
          component: :worker,
          outcome: :error,
          reason: reason,
          job_id: job_id
        )

        :error
    end
  end

  # The bounded error code travels with the failure, so a job that finally
  # gives up can still be explained by whoever looks at it later rather than by
  # the log line that has since rotated away.
  defp fail(storage, job_id, reason) do
    case storage.fail_job(job_id, Observability.error_code(reason)) do
      :ok ->
        Observability.log(:error,
          component: :worker,
          outcome: :failed,
          reason: reason,
          job_id: job_id
        )

        :failed

      {:error, error} ->
        Observability.log(:error,
          component: :worker,
          outcome: :error,
          reason: error,
          job_id: job_id
        )

        :error
    end
  end
end
