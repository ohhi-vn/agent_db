defmodule AgentDb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Set default configuration values
    put_default_config()

    data_dir = AgentDb.Config.data_dir()
    File.mkdir_p!(data_dir)
    path = Path.join(data_dir, "agent_db.db")

    children = [
      # Ahead of the endpoint: config names AgentDb.PubSub as the pubsub_server,
      # and subscribing to a name with no server raises. Declaring a dependency
      # without starting it is the same class of defect as configuring a
      # listener without setting `server: true`.
      {Phoenix.PubSub, name: AgentDb.PubSub},
      AgentDb.Cache.Owner,
      {AgentDb.Store.Writer, path: path},
      {AgentDb.Store.Reader, path: path},
      AgentDb.ML.ModelManager,
      {AgentDb.Workers.EmbeddingWorker, worker_id: "embedding_worker_1"},
      {AgentDb.Workers.SummarizationWorker, worker_id: "summarization_worker_1"}
    ]

    # Conditionally add HTTP gateway (new Phoenix web endpoint with router)
    http_children =
      if AgentDb.Config.http_enabled() do
        [
          {AgentDbWeb.Endpoint, []}
        ]
      else
        []
      end

    all_children = children ++ http_children

    opts = [strategy: :one_for_one, name: AgentDb.Supervisor]
    {:ok, supervisor} = Supervisor.start_link(all_children, opts)

    # Initialize schema and job queue after supervisor starts
    initialize_database(path)

    {:ok, supervisor}
  end

  @impl true
  def stop(_state) do
    # Graceful shutdown: drain job queues, wait for workers
    graceful_shutdown()
    :ok
  end

  defp initialize_database(path) do
    {:ok, conn} = AgentDb.Store.SQLite.open(path)
    AgentDb.Store.SQLite.ensure_schema(conn)
    AgentDb.JobQueue.reset_running_jobs()
    AgentDb.Store.SQLite.close(conn)
  end

  defp graceful_shutdown do
    # Signal workers to stop processing
    stop_workers()
    
    # Wait for pending jobs to complete (with timeout)
    wait_for_jobs_completion(5_000)
    
    # Shutdown ModelManager
    GenServer.stop(AgentDb.ML.ModelManager, :shutdown, 2_000)
    
    # Close database connections
    close_connections()
  end

  defp stop_workers do
    # Stop embedding worker
    case GenServer.whereis({:via, :global, "embedding_worker_1"}) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown, 5_000)
    end
    
    # Stop summarization worker
    case GenServer.whereis({:via, :global, "summarization_worker_1"}) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown, 5_000)
    end
  end

  defp wait_for_jobs_completion(timeout) do
    start_time = System.monotonic_time(:millisecond)
    
    loop_until(fn ->
      {:ok, stats} = AgentDb.JobQueue.stats()
      pending = Map.get(stats, :pending, 0) + Map.get(stats, :running, 0)
      pending == 0
    end, timeout, start_time)
  end

  defp loop_until(condition_fn, timeout, start_time) do
    if condition_fn.() do
      :ok
    else
      elapsed = System.monotonic_time(:millisecond) - start_time
      if elapsed >= timeout do
        Logger.warn("Timeout waiting for jobs to complete")
        :ok
      else
        :timer.sleep(100)
        loop_until(condition_fn, timeout, start_time)
      end
    end
  end

  defp close_connections do
    # The Writer and Reader GenServers will be stopped by the supervisor
    # Their terminate callbacks will close the connections
    :ok
  end

  defp put_default_config do
    # Model cache directory
    Application.put_env(:agent_db, :model_cache_dir,
      System.get_env("AGENT_DB_MODEL_CACHE_DIR") ||
        Path.join(File.cwd!(), "models"))

    # Embedding model configuration
    Application.put_env(:agent_db, :embedding_model,
      System.get_env("AGENT_DB_EMBEDDING_MODEL") ||
        "sentence-transformers/all-MiniLM-L6-v2")

    Application.put_env(:agent_db, :embedding_model_url,
      System.get_env("AGENT_DB_EMBEDDING_MODEL_URL") ||
        "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/model.safetensors")

    # LLM model configuration
    Application.put_env(:agent_db, :llm_model,
      System.get_env("AGENT_DB_LLM_MODEL") ||
        "microsoft/Phi-3-mini-4k-instruct")

    Application.put_env(:agent_db, :llm_model_url,
      System.get_env("AGENT_DB_LLM_MODEL_URL") ||
        "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct/resolve/main/model-q4_k_m.gguf")

    # Write mode: async (default) or sync
    async_writes =
      case System.get_env("AGENT_DB_ASYNC_WRITES") do
        nil -> true
        value -> String.downcase(value) == "true"
      end
    Application.put_env(:agent_db, :async_writes, async_writes)

    # Job worker pool size
    Application.put_env(:agent_db, :job_workers,
      case System.get_env("AGENT_DB_JOB_WORKERS") do
        nil -> System.schedulers_online()
        value -> String.to_integer(value)
      end)

    # EXLA backend: :cpu, :cuda, :rocm
    Application.put_env(:agent_db, :exla_backend,
      case System.get_env("AGENT_DB_EXLA_BACKEND") do
        "cuda" -> :cuda
        "rocm" -> :rocm
        _ -> :cpu
      end)

    # HTTP API configuration
    http_enabled =
      case System.get_env("AGENT_DB_HTTP_ENABLED") do
        # Off by default under test. The suite restarts the application from
        # many setup blocks, so a listener would be bound and released that many
        # times over and could collide with a running development instance --
        # and a failed bind takes the endpoint's start, and the suite, with it.
        # The reachability test opts in explicitly.
        nil -> Mix.env() != :test
        value -> String.downcase(value) == "true"
      end

    Application.put_env(:agent_db, :http_enabled, http_enabled)

    # The port is not resolved here. It is read in config/runtime.exs, which is
    # what builds the endpoint's `http:` and `url:` settings -- setting a
    # :http_port app env that nothing reads would suggest the port is
    # configurable here, and it is not.

    http_auth =
      case System.get_env("AGENT_DB_HTTP_AUTH") do
        nil -> false
        value -> String.downcase(value) == "true"
      end
    Application.put_env(:agent_db, :http_auth, http_auth)

    Application.put_env(:agent_db, :http_auth_tokens,
      case System.get_env("AGENT_DB_HTTP_AUTH_TOKENS") do
        nil -> []
        "" -> []
        tokens -> String.split(tokens, ",", trim: true)
      end)
  end
end