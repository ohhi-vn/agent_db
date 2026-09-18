defmodule AgentDb.Workers.EmbeddingWorker do
  @moduledoc """
  Background worker for generating document embeddings.
  
  Dequeues :embed jobs, generates embeddings via ModelManager, and stores
  them in the vec_nodes virtual table.
  """

  use GenServer

  alias AgentDb.JobQueue
  alias AgentDb.ML.ModelManager
  alias AgentDb.Store.{Nodes, SQLite, Writer}
  alias AgentDb.Cache.Invalidate

  require Logger

  @type state :: %{
          worker_id: String.t(),
          running: boolean()
        }

  # -- Client API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    worker_id = Keyword.get(opts, :worker_id, "embedding_worker_#{:erlang.unique_integer([:positive])}")
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
          process_embed_job(job)
          # Schedule next job
          Process.send_after(self(), :process_next, 0)

        {:error, :empty} ->
          # No jobs, wait and retry
          Process.send_after(self(), :process_next, 5_000)

        {:error, reason} ->
          Logger.error("Embedding worker #{state.worker_id} dequeue error: #{inspect(reason)}")
          Process.send_after(self(), :process_next, 5_000)
      end
    end
  end

  defp process_embed_job(%{id: job_id, kind: :embed, payload: payload, attempts: attempts}) do
    uri = payload["uri"]
    content = payload["content"]

    Logger.info("Processing embed job #{job_id} for #{uri} (attempt #{attempts})")

    case ModelManager.embed([content]) do
      {:ok, [embedding]} ->
        # Store embedding in vec_nodes
        Writer.call(fn conn ->
          case SQLite.exec_write(
                 conn,
                 """
                 INSERT INTO vec_nodes (embedding, uri)
                 VALUES (?1, ?2)
                 ON CONFLICT(uri) DO UPDATE SET embedding = excluded.embedding
                 """,
                 [to_binary(embedding), uri]
               ) do
            :ok ->
              # Update nodes.updated_at
              Nodes.update_updated_at(conn, uri, System.system_time(:millisecond))
              JobQueue.complete(job_id)
              Invalidate.on_write(uri)
              Logger.info("Embedding stored for #{uri}")
              :ok

            {:error, err} ->
              Logger.error("Failed to store embedding for #{uri}: #{inspect(err)}")
              JobQueue.fail(job_id, err)
              {:error, err}
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to generate embedding for #{uri}: #{inspect(reason)}")
        JobQueue.fail(job_id, reason)
    end
  end

  defp process_embed_job(%{id: job_id, kind: kind}), do: JobQueue.fail(job_id, {:invalid_kind, kind})

  defp to_binary(tensor) do
    # Convert Nx.Tensor to binary blob of float32 for sqlite-vec
    Nx.to_binary(tensor)
  end
end