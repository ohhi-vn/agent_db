defmodule AgentDb.ML.ModelManager do
  @moduledoc """
  Manages embedding and LLM models for vector search and summarization.

  Handles model download, caching, lazy loading, and inference.
  """

  use GenServer

  alias AgentDb.Config
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
  def init(_opts) do
    config = %{
      model_cache_dir: Config.model_cache_dir(),
      embedding_model: Config.embedding_model(),
      embedding_model_url: Config.embedding_model_url(),
      llm_model: Config.llm_model(),
      llm_model_url: Config.llm_model_url(),
      exla_backend: Config.exla_backend(),
      # Read at load time into model_ref, alongside the tokenizer and serving.
      llm_chat_template: Config.llm_chat_template(),
      llm_model_params: Config.llm_model_params(),
      # The only route to the model-loading library, so the load path can be
      # exercised without real weights. See AgentDb.ML.BumblebeeLoader.
      loader: AgentDb.ML.BumblebeeLoader
    }

    state = %State{
      embedding_model: nil,
      llm_model: nil,
      loading: %{},
      config: config
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:embed, texts}, _from, state) do
    case ensure_embedding_model(state) do
      {:ok, model_ref, new_state} ->
        {reply, new_state} = run_inference(&generate_embeddings(model_ref, &1), texts, new_state)
        {:reply, reply, new_state}

      # Either an already-running load, or one this call just started.
      {:error, :loading, new_state} ->
        {:reply, {:error, :model_loading}, new_state}
    end
  end

  @impl true
  def handle_call({:summarize, prompt, opts}, _from, state) do
    case ensure_llm_model(state) do
      {:ok, model_ref, new_state} ->
        {reply, new_state} =
          run_inference(&generate_summary(model_ref, &1, opts), prompt, new_state)

        {:reply, reply, new_state}

      {:error, :loading, new_state} ->
        {:reply, {:error, :model_loading}, new_state}
    end
  end

  @impl true
  def handle_call(:model_status, _from, state) do
    {:reply, build_model_status(state), state}
  end

  @impl true
  def handle_call({:load_status, role}, _from, state) do
    {:reply, load_status(state, role), state}
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

  # Inference failures are reported, never raised: an exception here would kill
  # the only inference process and discard the loaded model along with it.
  defp run_inference(fun, input, state) do
    case fun.(input) do
      {:ok, result} -> {{:ok, result}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  rescue
    error -> {{:error, {:inference_failed, error}}, state}
  catch
    :exit, reason -> {{:error, {:inference_failed, {:exit, reason}}}, state}
    :throw, value -> {{:error, {:inference_failed, {:throw, value}}}, state}
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

  defp perform_load(config, :embedding), do: load_embedding_model(config)
  defp perform_load(config, :llm), do: load_llm_model(config)

  defp load_embedding_model(config) do
    model_id = config.embedding_model

    # ensure_model_files/3 performs network I/O, so it is deliberately inside
    # the rescue: it used to be the scrutinee of the case and therefore outside
    # the try, which let a transport failure terminate this GenServer.
    with :ok <- ensure_model_files(model_id, config.embedding_model_url, config.model_cache_dir),
         {:ok, model_ref} <- build_model_ref(config, model_id, :embedding) do
      {:ok, model_ref}
    end
  end

  defp load_llm_model(config) do
    model_id = config.llm_model

    with :ok <- ensure_model_files(model_id, config.llm_model_url, config.model_cache_dir),
         {:ok, model_ref} <- build_model_ref(config, model_id, :llm) do
      {:ok, model_ref}
    end
  end

  # Bumblebee.load_model/2 already returns the loaded model as
  # {:ok, %{model: model, spec: spec}} -- it is a single call, not two phases.
  # Calling it a second time with that map used to raise ArgumentError, because
  # normalize_repository!/1 accepts only {:hf, id} or {:local, dir}.
  #
  # :backend is applied here so Config.exla_backend/0 stops being discarded.
  defp build_model_ref(config, model_id, role) do
    loader = config.loader

    with {:ok, tokenizer} <- loader.load_tokenizer({:hf, model_id}),
         {:ok, %{model: model, spec: spec}} <-
           loader.load_model({:hf, model_id}, backend: config.exla_backend) do
      {:ok,
       %{
         tokenizer: tokenizer,
         model: model,
         spec: spec,
         serving: loader.serving(role),
         # Snapshotted with the rest of the model, for the same reason: the
         # prompt format belongs to the model, and Bumblebee has no API that
         # returns it. A test overrides it the way it overrides the loader.
         chat_template: config.llm_chat_template
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to load #{inspect(role)} model: #{inspect(reason)}")
        {:error, wrap_load_error(reason)}

      unexpected ->
        Logger.error("Unexpected #{inspect(role)} load result: #{inspect(unexpected)}")
        {:error, wrap_load_error(unexpected)}
    end
  rescue
    error ->
      Logger.error("Raised while loading #{inspect(role)} model: #{inspect(error)}")
      {:error, wrap_load_error(error)}
  catch
    # An accelerator backend resolves through EXLA.Client, which reports a
    # missing platform by exiting rather than raising, so rescue alone would
    # let it terminate this process.
    :exit, reason ->
      Logger.error("Exited while loading #{inspect(role)} model: #{inspect(reason)}")
      {:error, wrap_load_error({:exit, reason})}

    :throw, value ->
      Logger.error("Threw while loading #{inspect(role)} model: #{inspect(value)}")
      {:error, wrap_load_error({:throw, value})}
  end

  # Already-classified errors pass through so callers can tell "could not be
  # obtained" from "could not be loaded".
  defp wrap_load_error({:download_failed, _} = reason), do: reason
  defp wrap_load_error({:model_not_found, _} = reason), do: reason
  defp wrap_load_error(reason), do: {:model_load_failed, reason}

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

    Logger.info("Downloading model from #{url} to #{model_file}")

    case Req.get(url, receive_timeout: @download_receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!(partial, body)
        File.rename!(partial, model_file)
        Logger.info("Model downloaded successfully")
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.error("Failed to download model: HTTP #{status}")
        {:error, {:download_failed, status}}

      {:error, reason} ->
        Logger.error("Failed to download model: #{inspect(reason)}")
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
    tokenizer = model_ref.tokenizer
    model = model_ref.model
    serving = model_ref.serving

    # Tokenize inputs
    {:ok, inputs} = serving.tokenize(tokenizer, texts)

    # Generate embeddings
    {:ok, outputs} =
      serving.generate(model, inputs, fn embedding ->
        Nx.to_flat_list(Nx.mean(embedding, axes: [1]))
      end)

    embeddings =
      Enum.map(outputs, fn output ->
        # Convert to tensor and normalize
        tensor = Nx.tensor(output.embedding)
        norm = Nx.sqrt(Nx.sum(Nx.pow(tensor, 2)))
        Nx.divide(tensor, norm)
      end)

    {:ok, embeddings}
  end

  defp generate_summary(model_ref, prompt, opts) do
    tokenizer = model_ref.tokenizer
    model = model_ref.model
    serving = model_ref.serving

    max_tokens = Keyword.get(opts, :max_tokens, 256)
    temperature = Keyword.get(opts, :temperature, 0.7)

    # Format the prompt with the configured chat format for this model.
    formatted_prompt = format_prompt(prompt, model_ref.chat_template)

    {:ok, inputs} = serving.tokenize(tokenizer, formatted_prompt)

    {:ok, outputs} =
      serving.generate(model, inputs, %{
        max_tokens: max_tokens,
        temperature: temperature,
        top_p: 0.9,
        return_probabilities: false
      })

    # Extract generated text
    generated =
      outputs
      |> List.first()
      |> Map.get(:text, "")
      |> strip_reasoning()

    # An empty result is returned as an error, not as "". That distinction
    # matters downstream: "" is truthy, so the worker would store it and
    # node.abstract || first_line(content) would resolve to "" forever,
    # silently disabling the fallback that keeps a document readable when the
    # model does not work. run_inference/3 passes this error tuple through.
    generated
  end

  # A hybrid reasoning model emits its intermediate reasoning before the
  # answer. The segment from the opening marker through the closing marker is
  # removed; anything after it is the answer. Text with no marker is returned
  # unchanged apart from trimming, so a model that does not reason is
  # unaffected.
  defp strip_reasoning(text) do
    text
    |> remove_reasoning_segment()
    |> case do
      "" -> {:error, {:empty_summary, :no_answer}}
      summary -> {:ok, summary}
    end
  end

  # An unterminated block yields no answer at all. That is the
  # budget-exhausted case -- the model reasoned and never got past it -- and
  # the reasoning is not something to store as a summary, so the whole
  # remainder is dropped and the caller sees an empty result.
  defp remove_reasoning_segment(text) do
    case String.split(text, "<think>", parts: 2) do
      [_only_answer] -> text
      [_reasoning, rest] -> after_think_block(rest)
    end
    |> String.trim()
  end

  defp after_think_block(rest) do
    case String.split(rest, "</think>", parts: 2) do
      [_unterminated] -> ""
      [_reasoning, answer] -> answer
    end
  end

  # The format comes from configuration rather than a literal here, because the
  # prompt format belongs to the model: a hardcoded one silently sends a prompt
  # in a format the configured model was never trained on, and nothing in the
  # type, the tests, or the config would connect the two to catch it.
  defp format_prompt(prompt, chat_template) do
    String.replace(chat_template, "%{prompt}", prompt)
  end

  defp build_model_status(%State{embedding_model: embedding_model, llm_model: llm_model} = state) do
    %{
      embedding: %{
        loaded: embedding_model != nil,
        state: state.loading |> Map.get(:embedding, :idle) |> load_state_name(),
        model: state.config.embedding_model,
        dim: 384
      },
      llm: %{
        loaded: llm_model != nil,
        state: state.loading |> Map.get(:llm, :idle) |> load_state_name(),
        model: state.config.llm_model,
        # Configured rather than literal: a hand-written size here describes a
        # model the store may not be running, and the http-api spec assertion
        # had to change every time the model did.
        params: state.config.llm_model_params
      },
      queue: %{
        # Will be populated by JobQueue
        pending: 0
      }
    }
  end
end
