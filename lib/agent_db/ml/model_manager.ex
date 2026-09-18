defmodule AgentDb.ML.ModelManager do
  @moduledoc """
  Manages embedding and LLM models for vector search and summarization.
  
  Handles model download, caching, lazy loading, and inference.
  """

  use GenServer

  alias AgentDb.Config
  alias AgentDb.ML.ModelManager.State

  require Logger

  @type model_ref :: %{
          tokenizer: Bumblebee.Tokenizer.t(),
          model: Bumblebee.Model.t(),
          config: map(),
          serving: module()
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

  @doc "Generates embeddings for the given texts."
  @spec embed([String.t()]) :: {:ok, [Nx.Tensor.t()]} | {:error, term()}
  def embed(texts) do
    GenServer.call(__MODULE__, {:embed, texts})
  end

  @doc "Generates a summary for the given prompt."
  @spec summarize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize(prompt, opts \\ []) do
    GenServer.call(__MODULE__, {:summarize, prompt, opts})
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
      exla_backend: Config.exla_backend()
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
    {:reply, reply, new_state} = do_embed(texts, state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:summarize, prompt, opts}, _from, state) do
    {:reply, reply, new_state} = do_summarize(prompt, opts, state)
    {:reply, reply, new_state}
  end

  @impl true
  def handle_call(:model_status, _from, state) do
    reply = build_model_status(state)
    {:reply, reply, state}
  end

  # -- Internal Implementation --

  defp do_embed(texts, state) do
    case ensure_embedding_model(state) do
      {:ok, model_ref, new_state} ->
        case generate_embeddings(model_ref, texts) do
          {:ok, embeddings} ->
            {:reply, {:ok, embeddings}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_summarize(prompt, opts, state) do
    case ensure_llm_model(state) do
      {:ok, model_ref, new_state} ->
        case generate_summary(model_ref, prompt, opts) do
          {:ok, summary} ->
            {:reply, {:ok, summary}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_embedding_model(state) do
    case state.embedding_model do
      nil ->
        load_embedding_model(state)

      model_ref ->
        {:ok, model_ref, state}
    end
  end

  defp ensure_llm_model(state) do
    case state.llm_model do
      nil ->
        load_llm_model(state)

      model_ref ->
        {:ok, model_ref, state}
    end
  end

  defp load_embedding_model(state) do
    config = state.config
    model_id = config.embedding_model
    cache_dir = config.model_cache_dir
    _backend = config.exla_backend

    # Ensure model files exist
    case ensure_model_files(model_id, config.embedding_model_url, cache_dir) do
      :ok ->
        try do
          # Load tokenizer and model
          {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})
          {:ok, model_info} = Bumblebee.load_model({:hf, model_id})
          model = Bumblebee.load_model(model_info)

          # Configure for EXLA backend
          serving = Bumblebee.Text.TextEmbedding
          model_ref = %{
            tokenizer: tokenizer,
            model: model,
            serving: serving
          }

          new_state = %{state | embedding_model: model_ref}
          {:ok, model_ref, new_state}
        catch
          :error, reason ->
            Logger.error("Failed to load embedding model: #{inspect(reason)}")
            {:error, {:model_load_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_llm_model(state) do
    config = state.config
    model_id = config.llm_model
    cache_dir = config.model_cache_dir
    _backend = config.exla_backend

    # Ensure model files exist
    case ensure_model_files(model_id, config.llm_model_url, cache_dir) do
      :ok ->
        try do
          # Load tokenizer and model for Phi-3-mini (GGUF format)
          {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})
          {:ok, model_info} = Bumblebee.load_model({:hf, model_id})
          model = Bumblebee.load_model(model_info)

          serving = Bumblebee.Text.Generation
          model_ref = %{
            tokenizer: tokenizer,
            model: model,
            serving: serving
          }

          new_state = %{state | llm_model: model_ref}
          {:ok, model_ref, new_state}
        catch
          :error, reason ->
            Logger.error("Failed to load LLM model: #{inspect(reason)}")
            {:error, {:model_load_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_model_files(model_id, model_url, cache_dir) do
    model_dir = Path.join(cache_dir, model_id)
    model_file = Path.join(model_dir, "model.safetensors")

    if File.exists?(model_file) do
      :ok
    else
      # In test environment, don't attempt downloads - return error quickly
      if Mix.env() == :test do
        {:error, {:model_not_found, model_file}}
      else
        download_model(model_url, model_dir, model_file)
      end
    end
  end

  defp download_model(url, model_dir, model_file) do
    File.mkdir_p!(model_dir)

    Logger.info("Downloading model from #{url} to #{model_file}")

    case Req.get!(url) do
      %Req.Response{status: 200, body: body} ->
        File.write!(model_file, body)
        Logger.info("Model downloaded successfully")
        :ok

      %Req.Response{status: status} ->
        Logger.error("Failed to download model: HTTP #{status}")
        {:error, {:download_failed, status}}

      error ->
        Logger.error("Failed to download model: #{inspect(error)}")
        {:error, {:download_failed, error}}
    end
  end

  defp generate_embeddings(model_ref, texts) do
    tokenizer = model_ref.tokenizer
    model = model_ref.model
    serving = model_ref.serving

    # Tokenize inputs
    {:ok, inputs} = serving.tokenize(tokenizer, texts)

    # Generate embeddings
    {:ok, outputs} = serving.generate(model, inputs, fn embedding -> Nx.to_flat_list(Nx.mean(embedding, axes: [1])) end)

    embeddings = Enum.map(outputs, fn output ->
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

    # Format prompt for Phi-3-mini chat template
    formatted_prompt = format_prompt(prompt)

    {:ok, inputs} = serving.tokenize(tokenizer, formatted_prompt)

    {:ok, outputs} = serving.generate(model, inputs, %{
      max_tokens: max_tokens,
      temperature: temperature,
      top_p: 0.9,
      return_probabilities: false
    })

    # Extract generated text
    generated = outputs
    |> List.first()
    |> Map.get(:text, "")
    |> String.trim()

    {:ok, generated}
  end

  defp format_prompt(prompt) do
    # Phi-3-mini chat format
    "<|user|>\n#{prompt}<|end|>\n<|assistant|>"
  end

  defp build_model_status(%State{embedding_model: embedding_model, llm_model: llm_model} = state) do
    %{
      embedding: %{
        loaded: embedding_model != nil,
        model: state.config.embedding_model,
        dim: 384
      },
      llm: %{
        loaded: llm_model != nil,
        model: state.config.llm_model,
        params: "3.8B"
      },
      queue: %{
        pending: 0  # Will be populated by JobQueue
      }
    }
  end
end