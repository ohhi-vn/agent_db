defmodule AgentDb.ML.ModelManager.Backend do
  @moduledoc """
  Runtime that loads embedding and summarization models and runs inference.

  `Backend.Exla` is the current Bumblebee + EXLA path. `Backend.Emlx` is the
  Apple MLX path (EMLX + EMLXAxon). `ModelManager` selects one at startup and
  falls back to EXLA when EMLX is unavailable.
  """

  @type model_ref :: map()
  @type config :: map()

  @callback load_embedding(config()) :: {:ok, model_ref()} | {:error, term()}
  @callback load_llm(config()) :: {:ok, model_ref()} | {:error, term()}
  @callback embed(model_ref(), [String.t()]) :: {:ok, [Nx.Tensor.t()]} | {:error, term()}
  @callback summarize(model_ref(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback model_info() :: %{backend: atom()}

  @doc "Resolves `:auto` to `:emlx` on Apple Silicon macOS, else `:exla`."
  @spec resolve(:auto | :exla | :emlx) :: :exla | :emlx
  def resolve(:exla), do: :exla
  def resolve(:emlx), do: :emlx
  def resolve(:auto), do: if(apple_silicon?(), do: :emlx, else: :exla)
  def resolve(_), do: :exla

  @doc false
  @spec apple_silicon?() :: boolean()
  def apple_silicon? do
    match?({:unix, :darwin}, :os.type()) and
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.contains?(["arm", "aarch64"])
  end

  @doc "Backend module for a resolved backend name."
  @spec module_for(:exla | :emlx) :: module()
  def module_for(:emlx), do: AgentDb.ML.ModelManager.Backend.Emlx
  def module_for(_), do: AgentDb.ML.ModelManager.Backend.Exla
end
