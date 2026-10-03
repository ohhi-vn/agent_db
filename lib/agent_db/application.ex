defmodule AgentDb.Application do
  @moduledoc false

  use Application

  # Starts the store: which providers serve it, and in what order.
  #
  # The order is a dependency chain rather than a preference. The cache exists
  # to sit in front of the database, so it starts first. Storage comes next
  # because inference and the workers both reach it. Inference starts before the
  # workers, so a job is never claimed by a worker whose model process is not
  # there to answer it. The transport starts last, because it can be asked for
  # state that nothing else has produced yet.
  #
  # A health endpoint that answers before the store is ready is worse than one
  # that refuses to start: it reports on a store that cannot yet serve.
  #
  # Shutdown runs the other way, which the supervisor gets for free: the
  # transport stops, then the workers drain what is in flight, then inference,
  # then the connections.

  @impl Application
  def start(_type, _args) do
    put_default_config()
    maybe_start_emlx()

    data_dir = AgentDb.Config.data_dir()
    File.mkdir_p!(data_dir)
    path = AgentDb.Config.db_path()
    opts = [path: path]

    # A provider that cannot answer its port is a configuration error, and this
    # is the last moment it can be corrected.
    :ok = AgentDb.Runtime.validate!()

    children =
      pubsub_specs() ++
        cache_specs() ++
        [AgentDb.Observability.Sink] ++
        AgentDb.Runtime.storage().child_specs(opts) ++
        AgentDb.Runtime.inference().child_specs(opts) ++
        worker_specs() ++
        transport_specs(opts)

    {:ok, supervisor} =
      Supervisor.start_link(children, strategy: :one_for_one, name: AgentDb.Supervisor)

    initialize()

    {:ok, supervisor}
  end

  @impl Application
  def stop(_state) do
    drain(AgentDb.Config.shutdown_grace_ms())
    :ok
  end

  # Jobs left running by a process that died are not lost and not running:
  # they go back to pending, so the workers that start next can claim them.
  defp initialize do
    AgentDb.Runtime.storage().reset_running_jobs()
  end

  # Started ahead of everything that reads through it, and ahead of whichever
  # storage provider is in use, because the cache belongs to the application
  # layer rather than to a provider. A provider that is not SQLite serves the
  # same reads, so it needs the same cache in front of it.
  defp cache_specs, do: [AgentDb.Cache]

  # The store's own pubsub, started whether or not a transport is serving. The
  # endpoint's configuration names it, and subscribing to a name with no server
  # raises -- so a deployment that turns HTTP off must not also break anything
  # that publishes to it.
  defp pubsub_specs, do: [{Phoenix.PubSub, name: AgentDb.PubSub}]

  @doc false
  def worker_specs do
    count = AgentDb.Config.job_workers()

    unless is_integer(count) and count > 0 do
      raise ArgumentError,
            "job_workers must be a positive integer, got: #{inspect(count)}"
    end

    embedding =
      for n <- 1..count do
        Supervisor.child_spec(
          {AgentDb.Workers.Embedding, [worker_id: AgentDb.Workers.Embedding.registration(n)]},
          id: {AgentDb.Workers.Embedding, n}
        )
      end

    summarization =
      for n <- 1..count do
        Supervisor.child_spec(
          {AgentDb.Workers.Summarization,
           [worker_id: AgentDb.Workers.Summarization.registration(n)]},
          id: {AgentDb.Workers.Summarization, n}
        )
      end

    embedding ++ summarization
  end

  defp transport_specs(opts) do
    if AgentDb.Runtime.transport().enabled?() do
      AgentDb.Runtime.transport().child_specs(opts)
    else
      []
    end
  end

  # Work already claimed is allowed to finish, within a bound. The supervisor
  # has already stopped the workers by the time this runs, so this waits for
  # the queue to reach a steady state rather than for a process that is gone.
  @drain_poll_ms 100

  defp drain(grace_ms) do
    wait_until_idle(System.monotonic_time(:millisecond) + grace_ms)
  end

  defp wait_until_idle(deadline) do
    if outstanding() > 0 and System.monotonic_time(:millisecond) < deadline do
      :timer.sleep(@drain_poll_ms)
      wait_until_idle(deadline)
    else
      :ok
    end
  end

  defp outstanding do
    case AgentDb.Runtime.storage().queue_stats() do
      {:ok, stats} -> Map.get(stats, :pending, 0) + Map.get(stats, :running, 0)
      {:error, _} -> 0
    end
  end

  # Defaults for settings a deployment may have left out. Each is read from the
  # environment first, so a container can be configured without a config file.
  defp put_default_config do
    put_env(:model_cache_dir, System.get_env("AGENT_DB_MODEL_CACHE_DIR") || cwd("models"))

    put_env(
      :embedding_model,
      System.get_env("AGENT_DB_EMBEDDING_MODEL") || "sentence-transformers/all-MiniLM-L6-v2"
    )

    put_env(
      :embedding_model_url,
      System.get_env("AGENT_DB_EMBEDDING_MODEL_URL") ||
        "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/model.safetensors"
    )

    put_env(:llm_model, System.get_env("AGENT_DB_LLM_MODEL") || "Qwen/Qwen3-0.6B")

    put_env(
      :llm_model_url,
      System.get_env("AGENT_DB_LLM_MODEL_URL") ||
        "https://huggingface.co/tensorblock/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
    )

    # The prompt format belongs to the model, and no model library returns its
    # own, so it is configured to match whichever model is selected. Setting
    # this to a different model's format is what stops a prompt being sent in a
    # shape that model was never built for.
    put_env(
      :llm_chat_template,
      System.get_env("AGENT_DB_LLM_CHAT_TEMPLATE") ||
        "<|im_start|>user\n%{prompt}<|im_end|>\n<|im_start|>assistant\n"
    )

    # Descriptive only: reported in model status, never used to load anything.
    put_env(:llm_model_params, System.get_env("AGENT_DB_LLM_MODEL_PARAMS") || "0.6B")

    put_env(:async_writes, boolean_env("AGENT_DB_ASYNC_WRITES", true))
    put_env(:job_workers, integer_env("AGENT_DB_JOB_WORKERS", System.schedulers_online()))
    put_env(:exla_backend, backend_env())
    put_env(:ml_backend, ml_backend_env())

    # Off by default under test. The suite restarts the application from many
    # setup blocks, so a listener would be bound and released that many times
    # and could collide with a running development instance; a failed bind takes
    # the endpoint's start, and the suite, with it.
    put_env(:http_enabled, boolean_env("AGENT_DB_HTTP_ENABLED", Mix.env() != :test))
    put_env(:http_auth, boolean_env("AGENT_DB_HTTP_AUTH", false))
    put_env(:http_auth_tokens, tokens_env())
  end

  defp put_env(key, value), do: Application.put_env(:agent_db, key, value)

  defp cwd(name), do: Path.join(File.cwd!(), name)

  defp boolean_env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.downcase(value) == "true"
    end
  end

  defp integer_env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp tokens_env do
    case System.get_env("AGENT_DB_HTTP_AUTH_TOKENS") do
      nil -> []
      "" -> []
      tokens -> String.split(tokens, ",", trim: true)
    end
  end

  defp backend_env do
    case System.get_env("AGENT_DB_EXLA_BACKEND") do
      "cuda" -> :cuda
      "rocm" -> :rocm
      _other -> :cpu
    end
  end

  defp ml_backend_env do
    case System.get_env("AGENT_DB_ML_BACKEND") do
      "exla" -> :exla
      "emlx" -> :emlx
      _other -> :auto
    end
  end

  # EMLX ships with `runtime: false` so non-macOS installs never start it.
  # When the configured backend needs it on Apple Silicon, ensure it is
  # started; failures are ignored because ModelManager falls back to EXLA.
  defp maybe_start_emlx do
    if emlx_needed?() and Code.ensure_loaded?(EMLX) do
      _ = Application.ensure_all_started(:emlx)
      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp emlx_needed? do
    case AgentDb.Config.ml_backend() do
      :emlx -> true
      :auto -> AgentDb.ML.ModelManager.Backend.apple_silicon?()
      _ -> false
    end
  end
end
