defmodule AgentDb.Workers.SummarizationWorker do
  @moduledoc """
  Background worker for generating document summaries (abstracts and overviews).
  
  Dequeues :summarize_abstract and :summarize_overview jobs, generates summaries
  via ModelManager, and updates the nodes table.
  """

  use GenServer

  alias AgentDb.JobQueue
  alias AgentDb.ML.ModelManager
  alias AgentDb.Store.{Nodes, SQLite, Writer}
  alias AgentDb.Cache.Invalidate

  require Logger

  @model_loading_delay_ms 1_000

  @type state :: %{
          worker_id: String.t(),
          running: boolean()
        }

  # -- Client API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    worker_id = Keyword.get(opts, :worker_id, "summarization_worker_#{:erlang.unique_integer([:positive])}")
    GenServer.start_link(__MODULE__, worker_id, name: {:via, :global, worker_id})
  end

  # -- Server Callbacks --

  @impl true
  def init(worker_id) do
    state = %{worker_id: worker_id, running: true}
    {:ok, state}
  end

  @impl true
  def handle_continue(:work, state) do
    process_job(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_next, state) do
    process_job(state)
    {:noreply, state}
  end

  # -- Internal --

  defp process_job(state) do
    if state.running do
      case JobQueue.dequeue(state.worker_id) do
        {:ok, job} ->
          process_summarize_job(job)
          Process.send_after(self(), :process_next, 0)

        {:error, :empty} ->
          Process.send_after(self(), :process_next, 5_000)

        {:error, reason} ->
          Logger.error("Summarization worker #{state.worker_id} dequeue error: #{inspect(reason)}")
          Process.send_after(self(), :process_next, 5_000)
      end
    end
  end

  defp process_summarize_job(%{id: job_id, kind: :summarize_abstract, payload: payload, attempts: attempts}) do
    uri = payload["uri"]
    content = payload["content"]

    Logger.info("Processing abstract summarization job #{job_id} for #{uri} (attempt #{attempts})")

    prompt = build_abstract_prompt(content)
    process_summarization(job_id, uri, prompt, :abstract)
  end

  defp process_summarize_job(%{id: job_id, kind: :summarize_overview, payload: payload, attempts: attempts}) do
    uri = payload["uri"]
    content = payload["content"]

    Logger.info("Processing overview summarization job #{job_id} for #{uri} (attempt #{attempts})")

    prompt = build_overview_prompt(content)
    process_summarization(job_id, uri, prompt, :overview)
  end

  defp process_summarize_job(%{id: job_id, kind: kind}), do: JobQueue.fail(job_id, {:invalid_kind, kind})

  defp process_summarization(job_id, uri, prompt, field) do
    case ModelManager.summarize(prompt, max_tokens: 256) do
      {:ok, summary} ->
        Writer.call(fn conn ->
          # The node may have been removed while the LLM was running. Summaries
          # are computed outside any transaction, so a removal that committed
          # mid-compute is invisible until we look now, and cancelling the
          # queued job cannot help because dequeue/1 already claimed it. Check
          # on the same connection that persists the result.
          case Nodes.exists?(conn, uri) do
            {:ok, false} ->
              Logger.info("Discarding #{field} for removed #{uri}")
              JobQueue.complete(conn, job_id)
              :ok

            {:ok, true} ->
              store_summary(conn, job_id, uri, summary, field)

            {:error, reason} ->
              Logger.error("Existence check failed for #{uri}: #{inspect(reason)}")
              JobQueue.fail(conn, job_id, reason)
              {:error, reason}
          end
        end)

      # See EmbeddingWorker: waiting for a model is not a failure and must not
      # consume the job's retry budget.
      {:error, :model_loading} ->
        Logger.info("Deferring #{field} for #{uri}: model still loading")
        JobQueue.defer(job_id, @model_loading_delay_ms)

      {:error, reason} ->
        Logger.error("Failed to generate #{field} for #{uri}: #{inspect(reason)}")
        JobQueue.fail(job_id, reason)
    end
  end

  defp store_summary(conn, job_id, uri, summary, field) do
    field_col = if field == :abstract, do: "abstract", else: "overview"

    case SQLite.exec_write(
           conn,
           "UPDATE nodes SET #{field_col} = ?1, updated_at = ?2 WHERE uri = ?3",
           [summary, System.system_time(:millisecond), uri]
         ) do
      :ok ->
        JobQueue.complete(conn, job_id)
        Invalidate.on_write(uri)
        Logger.info("#{field} generated for #{uri}")
        :ok

      {:error, err} ->
        Logger.error("Failed to store #{field} for #{uri}: #{inspect(err)}")
        JobQueue.fail(conn, job_id, err)
        {:error, err}
    end
  end

  defp build_abstract_prompt(content) do
    """
    Summarize the following text in ONE sentence capturing the core point:

    #{content}

    Abstract:
    """
  end

  defp build_overview_prompt(content) do
    """
    Provide a concise structured overview (3-5 sentences) of the following text:

    #{content}

    Overview:
    """
  end
end