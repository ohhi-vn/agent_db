defmodule AgentDb.Workers.SummarizationWorker do
  @moduledoc """
  Background worker for generating document summaries (abstracts and overviews).
  
  Dequeues :summarize_abstract and :summarize_overview jobs, generates summaries
  via ModelManager, and updates the nodes table.
  """

  use GenServer

  alias AgentDb.JobQueue
  alias AgentDb.ML.ModelManager
  alias AgentDb.Store.{SQLite, Writer}
  alias AgentDb.Cache.Invalidate

  require Logger

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
          field_col = if field == :abstract, do: "abstract", else: "overview"
          case SQLite.exec_write(
                 conn,
                 "UPDATE nodes SET #{field_col} = ?1, updated_at = ?2 WHERE uri = ?3",
                 [summary, System.system_time(:millisecond), uri]
               ) do
            :ok ->
              JobQueue.complete(job_id)
              Invalidate.on_write(uri)
              Logger.info("#{field} generated for #{uri}")
              :ok

            {:error, err} ->
              Logger.error("Failed to store #{field} for #{uri}: #{inspect(err)}")
              JobQueue.fail(job_id, err)
              {:error, err}
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to generate #{field} for #{uri}: #{inspect(reason)}")
        JobQueue.fail(job_id, reason)
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