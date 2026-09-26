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
  @spec backend_spec(:cpu | :cuda | :rocm) :: :none | {module(), keyword()}
  def backend_spec(:cpu), do: :none

  def backend_spec(name) when name in [:cuda, :rocm] do
    {EXLA.Backend, [client: EXLA.Client.fetch!(name)]}
  end

  @doc "The Bumblebee serving module that runs a model in the given role."
  @spec serving(role()) :: module()
  def serving(:embedding), do: Bumblebee.Text.TextEmbedding
  def serving(:llm), do: Bumblebee.Text.Generation
end
