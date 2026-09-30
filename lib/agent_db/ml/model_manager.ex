defmodule AgentDb.ML.ModelManager do
  @moduledoc """
  Manages embedding and LLM models for vector search and summarization.

  Handles model download, caching, lazy loading, and inference.
  """

  use GenServer

  alias AgentDb.Config
  alias AgentDb.ML.ModelManager.Backend
  alias AgentDb.ML.ModelManager.State

  require Logger

  # Explicit rather than relying on Req's 15s default, so a slow host cannot
  # block the inference process indefinitely. Not yet configurable; timeout
  # policy belongs with the loader-split change.
  @download_receive_timeout 30_000

  # Explicit rather than GenServer.call's 5s default. A call now returns
  # :model_loading immediately unless the model is already loaded, in which
  # case it runs inference and needs room for it.
  @call_timeout 60_000

  @load_poll_interval_ms 50

  @type model_ref :: %{
          tokenizer: Bumblebee.Tokenizer.t(),
          model: Bumblebee.Model.t(),
          config: map(),
          serving: module(),
          chat_template: String.t()
        }

  @type state :: %State{
          embedding_model: model_ref() | nil,
          llm_model: model_ref() | nil,
          loading: map(),
          config: map()
        }

  # -- Client API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates embeddings for the given texts.

  Returns `{:error, :model_loading}` when the model is not ready and has not
  become ready within `Config.model_load_grace_ms/0`. That is distinct from a
  load that failed, and the call is safe to repeat.
  """
  @spec embed([String.t()]) :: {:ok, [Nx.Tensor.t()]} | {:error, term()}
  def embed(texts) do
    await_model(fn -> GenServer.call(__MODULE__, {:embed, texts}, @call_timeout) end, :embedding)
  end

  @doc """
  Generates a summary for the given prompt.

  Returns `{:error, :model_loading}` when the model is not ready and has not
  become ready within `Config.model_load_grace_ms/0`.
  """
  @spec summarize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize(prompt, opts \\ []) do
    await_model(
      fn -> GenServer.call(__MODULE__, {:summarize, prompt, opts}, @call_timeout) end,
      :llm
    )
  end

  # The load happens outside the GenServer, so a call returns :model_loading
  # almost immediately. The wait lives here, in the caller, so that a model
  # which becomes ready inside the grace period is invisible to it.
  defp await_model(call, role) do
    case call.() do
      {:error, :model_loading} ->
        case wait_for_load(role, Config.model_load_grace_ms()) do
          :ready ->
            call.()

          # A load that failed during the wait is reported as the failure it
          # was. Reporting :model_loading here would tell the caller to retry
          # something that will keep failing.
          {:failed, reason} ->
            {:error, reason}

          :timeout ->
            {:error, :model_loading}
        end

      other ->
        other
    end
  end

  defp wait_for_load(role, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    poll_until_loaded(role, deadline)
  end

  defp poll_until_loaded(role, deadline) do
    case load_status_for(role) do
      :ready ->
        :ready

      {:failed, reason} ->
        {:failed, reason}

      _loading_or_idle ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@load_poll_interval_ms)
          poll_until_loaded(role, deadline)
        end
    end
  end

  defp load_status_for(role) do
    GenServer.call(__MODULE__, {:load_status, role}, @call_timeout)
  end

  @doc "Returns the status of both models."
  @spec model_status() :: map()
  def model_status do
    GenServer.call(__MODULE__, :model_status)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    requested = Keyword.get(opts, :ml_backend, Config.ml_backend())
    resolved = Backend.resolve(requested)

    config = %{
      model_cache_dir: Config.model_cache_dir(),
      embedding_model: Config.embedding_model(),
      embedding_model_url: Config.embedding_model_url(),
      llm_model: Config.llm_model(),
      llm_model_url: Config.llm_model_url(),
      exla_backend: Config.exla_backend(),
      ml_backend_requested: requested,
      ml_backend: resolved,
      backend: Backend.module_for(resolved),
      # Read at load time into model_ref, alongside the tokenizer and serving.
      llm_chat_template: Config.llm_chat_template(),
      llm_model_params: Config.llm_model_params(),
      # The only route to the model-loading library, so the load path can be
      # exercised without real weights. See AgentDb.ML.BumblebeeLoader.
      loader: Keyword.get(opts, :loader, AgentDb.ML.BumblebeeLoader)
    }

    state = %State{
      embedding_model: nil,
      llm_model: nil,
      loading: %{},
      config: config
    }

    {:ok, state}
  end

  @doc "The resolved ML backend (`:exla` or `:emlx`)."
  @spec backend() :: :exla | :emlx
  def backend do
    GenServer.call(__MODULE__, :backend)
  end

  @impl true
  def handle_call({:embed, texts}, from, state) do
    case ensure_embedding_model(state) do
      {:ok, model_ref, new_state} ->
        dispatch_inference(from, :embedding, new_state, &generate_embeddings(model_ref, &1), texts)

      # Either an already-running load, or one this call just started.
      {:error, :loading, new_state} ->
        {:reply, {:error, :model_loading}, new_state}
    end
  end

  @impl true
  def handle_call({:summarize, prompt, opts}, from, state) do
    case ensure_llm_model(state) do
      {:ok, model_ref, new_state} ->
        dispatch_inference(from, :llm, new_state, &generate_summary(model_ref, &1, opts), prompt)

      {:error, :loading, new_state} ->
        {:reply, {:error, :model_loading}, new_state}
    end
  end

  @impl true
  def handle_call(:model_status, _from, state) do
    {:reply, build_model_status(state), state}
  end

  @impl true
  def handle_call(:backend, _from, state) do
    {:reply, state.config.ml_backend, state}
  end

  @impl true
  def handle_call({:load_status, role}, _from, state) do
    {:reply, load_status(state, role), state}
  end

  @impl true
  def handle_info({:inference_result, ref, from, role, result}, state) do
    # A run this manager did not start is dropped: the caller has already
    # timed out, or the manager that owned the model has been replaced, so
    # there is nobody left to answer.
    if MapSet.member?(state.inference_refs, ref) do
      {reply, new_state} = finish_inference(role, result, state)

      GenServer.reply(from, reply)

      {:noreply,
       %{
         new_state
         | inference_refs: MapSet.delete(new_state.inference_refs, ref),
           in_flight: max(new_state.in_flight - 1, 0)
       }}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:load_result, ref, role, result}, state) do
    # A load runs outside this process and casts its result back by name, so a
    # result can outlive the manager that started it -- after a restart, or
    # when a new load has already begun. Only the in-flight load for THIS role
    # may write: state.loading_ref[role] is nil for a role that is not loading,
    # and for every role in a manager that has just started, so a leftover
    # result matches nothing and is dropped.
    if state.loading_ref[role] == ref do
      {:noreply, apply_load_result(role, result, state)}
    else
      {:noreply, state}
    end
  end

  # -- Internal Implementation --

  # Inference runs outside this process, for the same reason a load does: a run
  # holds the model for as long as the model takes, and doing that in
  # handle_call/3 would make every other caller -- including one merely asking
  # for status -- wait behind it. A loaded model is read-only to a run, so
  # concurrent runs are safe; the bound below is what keeps that from turning
  # into unbounded memory use.
  defp dispatch_inference(from, role, state, fun, input) do
    start = System.monotonic_time(:millisecond)

    if state.in_flight < Config.inference_concurrency() do
      ref = make_ref()

      _ =
        Task.start(fn ->
          send(__MODULE__, {:inference_result, ref, from, role, run_inference(role, fun, input, start)})
        end)

      {:noreply,
       %{
         state
         | inference_refs: MapSet.put(state.inference_refs, ref),
           in_flight: state.in_flight + 1
       }}
    else
      # At the bound, running inline is the backpressure: this caller waits
      # rather than starting another process the machine has no room for.
      {reply, duration} = run_inference(role, fun, input, start)
      GenServer.reply(from, reply)
      {:noreply, stamp_latency(state, role, duration)}
    end
  end

  defp stamp_latency(state, role, duration) do
    %{state | last_latency_ms: Map.put(state.last_latency_ms, role, duration)}
  end

  # Inference failures are reported, never raised: an exception here would
  # discard the loaded model along with the process that owns it. Every run
  # stamps its duration for the role, success or failure: it is still the last
  # inference latency, and status reads it without messaging.
  defp run_inference(role, fun, input, start) do
    result =
      try do
        case fun.(input) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      rescue
        error -> {:error, {:inference_failed, error}}
      catch
        :exit, reason -> {:error, {:inference_failed, {:exit, reason}}}
        :throw, value -> {:error, {:inference_failed, {:throw, value}}}
      end

    duration = System.monotonic_time(:millisecond) - start
    outcome = if match?({:ok, _}, result), do: :ok, else: :error
    AgentDb.Observability.emit_model(role, outcome, duration)

    {result, duration}
  end

  defp finish_inference(role, {result, duration}, state) do
    {result, stamp_latency(state, role, duration)}
  end

  defp apply_load_result(role, result, state) do
    case result do
      {:ok, model_ref} ->
        state
        |> Map.put(model_field(role), model_ref)
        |> put_load_status(role, :ready)

      {:error, reason} ->
        state
        |> Map.put(model_field(role), nil)
        |> put_load_status(role, {:failed, reason})
    end
  end

  defp model_field(:embedding), do: :embedding_model
  defp model_field(:llm), do: :llm_model

  defp put_load_status(state, role, status) do
    %{state | loading: Map.put(state.loading, role, status)}
  end

  defp load_state_name(:idle), do: :idle
  defp load_state_name(:loading), do: :loading
  defp load_state_name(:ready), do: :ready
  defp load_state_name({:failed, _reason}), do: :failed

  # Loading happens outside handle_call/3 so a multi-second (or, on a cold
  # start, multi-minute) load does not occupy the only inference process. A
  # caller that arrives first starts the load and is told it is loading; later
  # callers find the model ready.
  defp ensure_embedding_model(state), do: ensure_model(state, :embedding)

  defp ensure_llm_model(state), do: ensure_model(state, :llm)

  defp ensure_model(state, role) do
    case Map.get(state, model_field(role)) do
      nil ->
        # :idle, :ready and {:failed, _} all start a load. A previous failure
        # is retried rather than inherited, so a model that failed because it
        # was momentarily unavailable can still succeed later.
        if load_status(state, role) == :loading do
          {:error, :loading, state}
        else
          start_load(state, role)
        end

      model_ref ->
        {:ok, model_ref, state}
    end
  end

  defp load_status(state, role), do: Map.get(state.loading, role, :idle)

  # Task.start rather than a supervised child: build_model_ref/3 already
  # contains raise/exit/throw, and the load is a single pure step. The cast
  # back is what adopts the result, so a load can outlive the call that began
  # it and still be picked up by a later caller.
  defp start_load(state, role) do
    # make_ref/0, not a counter: a counter restarts at zero in each new
    # manager, so a load left over from a previous instance could present the
    # same reference as the current in-flight load and be accepted.
    #
    # Recorded under its own role. The two models load independently, so a
    # single shared reference would mean whichever load started second
    # invalidated the first, and that role would then report as loading
    # forever.
    ref = make_ref()
    spawn_load(state.config, role, ref)

    loading_ref = Map.put(state.loading_ref, role, ref)
    {:error, :loading, %{state | loading_ref: loading_ref} |> put_load_status(role, :loading)}
  end

  defp spawn_load(config, role, ref) do
    _ =
      Task.start(fn ->
        GenServer.cast(__MODULE__, {:load_result, ref, role, perform_load(config, role)})
      end)

    :ok
  end

  defp perform_load(config, role) when role in [:embedding, :llm] do
    start = System.monotonic_time(:millisecond)

    result =
      case role do
        :embedding -> load_embedding_model(config)
        :llm -> load_llm_model(config)
      end

    duration = System.monotonic_time(:millisecond) - start
    outcome = if match?({:ok, _}, result), do: :ok, else: :error
    AgentDb.Observability.emit_model(role, outcome, duration)
    result
  end

  defp load_embedding_model(config) do
    model_id = config.embedding_model

    with :ok <- ensure_model_files(model_id, config.embedding_model_url, config.model_cache_dir) do
      load_with_fallback(config, :embedding)
    end
  end

  defp load_llm_model(config) do
    model_id = config.llm_model

    with :ok <- ensure_model_files(model_id, config.llm_model_url, config.model_cache_dir) do
      load_with_fallback(config, :llm)
    end
  end

  defp load_with_fallback(%{ml_backend: :emlx, backend: backend} = config, role) do
    case apply(backend, load_fun(role), [config]) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "EMLX backend failed for #{inspect(role)}, falling back to EXLA: #{inspect(reason)}"
        )

        apply(Backend.module_for(:exla), load_fun(role), [config])
    end
  rescue
    _error ->
      Logger.warning("EMLX backend raised for #{inspect(role)}, falling back to EXLA")
      apply(Backend.module_for(:exla), load_fun(role), [config])
  catch
    :exit, _ ->
      Logger.warning("EMLX backend exited for #{inspect(role)}, falling back to EXLA")
      apply(Backend.module_for(:exla), load_fun(role), [config])

    :throw, _ ->
      Logger.warning("EMLX backend threw for #{inspect(role)}, falling back to EXLA")
      apply(Backend.module_for(:exla), load_fun(role), [config])
  end

  defp load_with_fallback(%{backend: backend} = config, role) do
    apply(backend, load_fun(role), [config])
  end

  defp load_fun(:embedding), do: :load_embedding
  defp load_fun(:llm), do: :load_llm

  defp ensure_model_files(model_id, model_url, cache_dir) do
    model_dir = Path.join(cache_dir, model_id)
    model_file = Path.join(model_dir, "model.safetensors")

    if File.exists?(model_file) do
      :ok
    else
      download_model(model_url, model_dir, model_file)
    end
  end

  # Writes to a .part path and renames into place, so a file at model_file is
  # proof of a completed download. Previously the body was written straight to
  # the final path, so a truncated file satisfied File.exists?/1 on every
  # later boot and then failed at load forever.
  defp download_model(url, model_dir, model_file) do
    if skip_remote_download_in_test?(url) do
      {:error, {:model_not_found, model_file}}
    else
      do_download_model(url, model_dir, model_file)
    end
  end

  # Keep the test suite off the network without also blocking the load path or
  # the download logic itself: loopback URLs are served by the test and are
  # always attempted.
  defp skip_remote_download_in_test?(url) do
    Mix.env() == :test and not String.starts_with?(url, "http://127.0.0.1")
  end

  defp do_download_model(url, model_dir, model_file) do
    partial = model_file <> ".part"
    File.mkdir_p!(model_dir)

    AgentDb.Observability.log(:info, component: :model, operation: :download, outcome: :started)

    case Req.get(url, receive_timeout: @download_receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!(partial, body)
        File.rename!(partial, model_file)
        AgentDb.Observability.log(:info, component: :model, operation: :download, outcome: :ok)
        :ok

      {:ok, %Req.Response{status: status}} ->
        AgentDb.Observability.log(:error,
          component: :model,
          operation: :download,
          outcome: :error,
          reason: {:download_failed, status}
        )

        {:error, {:download_failed, status}}

      {:error, reason} ->
        AgentDb.Observability.log(:error,
          component: :model,
          operation: :download,
          outcome: :error,
          reason: {:download_failed, :transport}
        )

        {:error, {:download_failed, reason}}
    end
    |> case do
      :ok ->
        :ok

      {:error, _} = error ->
        # Leave nothing behind that a later run would treat as a usable cache.
        File.rm(partial)
        error
    end
  end

  defp generate_embeddings(model_ref, texts) do
    backend_for(model_ref).embed(model_ref, texts)
  end

  defp generate_summary(model_ref, prompt, opts) do
    backend_for(model_ref).summarize(model_ref, prompt, opts)
  end

  defp backend_for(%{backend: :emlx}), do: Backend.module_for(:emlx)
  defp backend_for(_), do: Backend.module_for(:exla)

  defp build_model_status(%State{embedding_model: embedding_model, llm_model: llm_model} = state) do
    %{
      embedding: %{
        loaded: embedding_model != nil,
        state: state.loading |> Map.get(:embedding, :idle) |> load_state_name(),
        model: state.config.embedding_model,
        dim: 384,
        last_latency_ms: Map.get(state.last_latency_ms, :embedding)
      },
      llm: %{
        loaded: llm_model != nil,
        state: state.loading |> Map.get(:llm, :idle) |> load_state_name(),
        model: state.config.llm_model,
        # Configured rather than literal: a hand-written size here describes a
        # model the store may not be running, and the http-api spec assertion
        # had to change every time the model did.
        params: state.config.llm_model_params,
        last_latency_ms: Map.get(state.last_latency_ms, :llm)
      },
      queue: %{
        # Will be populated by JobQueue
        pending: 0
      },
      backend: state.config.ml_backend,
      memory_bytes: vm_memory()
    }
  end

  # The BEAM total, not a per-model figure: per-role memory is not measurable
  # from here, and a split would be invented. Same source as the runtime
  # snapshots, so the two never disagree about what "memory" means.
  defp vm_memory do
    :erlang.memory(:total)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
