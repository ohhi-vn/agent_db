defmodule AgentDb.ML.BumblebeeLoader do
  @moduledoc """
  Loads models through Bumblebee and reports which serving runs them.

  Isolates the Bumblebee API behind one module so the load path has a single
  seam. `AgentDb.ML.ModelManager` reaches the model-loading library only through
  this, which is what lets the load path be exercised without real weights.

  `load_model/2` is a single call that returns the already-loaded model as
  `{:ok, %{model: model, spec: spec}}`. It does not take the loaded result as
  input: `Bumblebee.normalize_repository!/1` accepts only `{:hf, id}` or
  `{:local, dir}` and raises `ArgumentError` on anything else.
  """

  @type repository :: {:hf, String.t()} | {:local, String.t()}
  @type role :: :embedding | :llm
  @type model_info :: map()

  @doc "Loads the tokenizer for a repository."
  @spec load_tokenizer(repository(), module()) :: {:ok, term()} | {:error, term()}
  def load_tokenizer(repository, lib \\ Bumblebee), do: lib.load_tokenizer(repository)

  @doc """
  Loads the model for a repository onto the backend named by `opts[:backend]`.

  `opts[:backend]` is AgentDb's own vocabulary — `:cpu`, `:cuda` or `:rocm`,
  the values `AgentDb.Config.exla_backend/0` returns. Bumblebee wants a backend
  *module* or `{module, opts}`, so it is translated here rather than passed
  through: an untranslated `:cpu` is read as a module named `:cpu` and raises.

  `:cpu` passes no `:backend` at all, which is Nx's default CPU backend.
  `:cuda`/`:rocm` require an EXLA client configured under `config :exla,
  clients`; without one, `EXLA.Client.fetch!/1` raises and the caller sees a
  load failure rather than a silent fall back to CPU.
  """
  @spec load_model(repository(), keyword(), module()) :: {:ok, term()} | {:error, term()}
  def load_model(repository, opts, lib \\ Bumblebee) do
    case backend_spec(Keyword.get(opts, :backend, :cpu)) do
      # Drop the key rather than passing it through: an untranslated :cpu would
      # be read by Bumblebee as a backend module named :cpu.
      :none -> lib.load_model(repository, Keyword.delete(opts, :backend))
      spec -> lib.load_model(repository, Keyword.put(opts, :backend, spec))
    end
  end

  @doc """
  Translates an AgentDb backend name into Bumblebee's `:backend` value.

  Returns `:none` to mean "do not pass a `:backend` option", which is how
  Bumblebee is told to use the default backend.
  """
  @spec backend_spec(:cpu | :cuda | :rocm | :emlx | {module(), keyword()}) ::
          :none | {module(), keyword()}
  def backend_spec(:cpu), do: :none

  def backend_spec(:emlx) do
    if Code.ensure_loaded?(EMLX.Backend), do: {EMLX.Backend, []}, else: :none
  end

  def backend_spec({mod, _opts} = spec) when is_atom(mod), do: spec

  def backend_spec(name) when name in [:cuda, :rocm] do
    {EXLA.Backend, [client: EXLA.Client.fetch!(name)]}
  end

  @doc """
  Builds the inference serving for a loaded model.

  Bumblebee builds an `Nx.Serving` from the model info and the tokenizer, and
  runs inference through that serving rather than through a tokenize/generate
  pair on the serving module. Loading therefore produces the serving itself,
  once, and `run/2` is the only inference entry point.

  `opts` carries the role's compile options (`:batch_size`,
  `:sequence_length`) and, for the LLM, the generation settings to configure
  (`:max_new_tokens`, `:temperature`, `:top_p`).
  """
  @spec build_serving(role(), model_info(), term(), keyword()) ::
          {:ok, Nx.Serving.t()} | {:error, term()}
  def build_serving(:embedding, model_info, tokenizer, opts) do
    # The default `output_attribute` is `:pooled_state`, which the encoder
    # already reduces to one vector per input, so there is nothing to pool here;
    # only the L2 normalization the vector index expects is left to do.
    {:ok,
     Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
       compile: compile_opts(opts),
       embedding_processor: :l2_norm
     )}
  end

  def build_serving(:llm, model_info, tokenizer, opts) do
    case load_generation_config(model_info, opts) do
      {:ok, config} ->
        {:ok,
         Bumblebee.Text.TextGeneration.generation(model_info, tokenizer, config,
           compile: compile_opts(opts)
         )}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Runs a built serving over `input` and returns its result.

  `Nx.Serving.run/2` answers with the serving's result directly rather than
  wrapping it, so an error is recognised by its own shape and anything else is
  a successful result. Inference goes through this one function so the
  Bumblebee API is reached from a single place, and a loader without Bumblebee
  installed can answer `build_serving/4` and `run/2` instead.
  """
  @spec run(Nx.Serving.t(), term()) :: {:ok, term()} | {:error, term()}
  def run(serving, input) do
    case Nx.Serving.run(serving, input) do
      {:error, reason} -> {:error, reason}
      result -> {:ok, result}
    end
  rescue
    error -> {:error, {:inference_failed, error}}
  catch
    :exit, reason -> {:error, {:inference_failed, {:exit, reason}}}
  end

  # The generation config ships with the repository rather than the model
  # weights, so it is loaded through the same repository the model came from.
  defp load_generation_config(model_info, opts) do
    repository = Map.get(model_info, :repository, {:local, "."})

    with {:ok, config} <- Bumblebee.load_generation_config(repository) do
      {:ok,
       Bumblebee.configure(config,
         max_new_tokens: Keyword.get(opts, :max_new_tokens, 256),
         temperature: Keyword.get(opts, :temperature, 0.7),
         top_p: Keyword.get(opts, :top_p, 0.9)
       )}
    end
  end

  defp compile_opts(opts) do
    [batch_size: Keyword.get(opts, :batch_size, 1), sequence_length: Keyword.get(opts, :sequence_length, 256)]
  end
end
