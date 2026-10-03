defmodule AgentDb.ML.ModelManager.Backend do
  @moduledoc """
  Runtime that loads embedding and summarization models and runs inference.

  `Backend.Exla` is the current Bumblebee + EXLA path. `Backend.Emlx` is the
  Apple MLX path (EMLX + EMLXAxon). `ModelManager` selects one at startup and
  falls back to EXLA when EMLX is unavailable.
  """

  @type model_ref :: map()
  @type config :: map()

  require Logger

  @callback load_embedding(config()) :: {:ok, model_ref()} | {:error, term()}
  @callback load_llm(config()) :: {:ok, model_ref()} | {:error, term()}
  @callback embed(model_ref(), [String.t()]) :: {:ok, [Nx.Tensor.t()]} | {:error, term()}
  @callback summarize(model_ref(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

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

  @doc """
  Loads a role's model through the configured backend, falling back to EXLA
  when the EMLX backend fails.

  The fallback lives here rather than in the manager because backend selection
  is this module's decision: the manager asks for a model to be loaded, not how
  the backend that loads it is chosen. A failure is reported, never raised, so
  the caller keeps its load-state machine intact.
  """
  @spec load(config(), :embedding | :llm) :: {:ok, model_ref()} | {:error, term()}
  def load(%{ml_backend: :emlx, backend: backend} = config, role) do
    case apply(backend, load_fun(role), [config]) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          "EMLX backend failed for #{inspect(role)}, falling back to EXLA: #{inspect(reason)}"
        )

        apply(module_for(:exla), load_fun(role), [config])
    end
  rescue
    _error ->
      Logger.warning("EMLX backend raised for #{inspect(role)}, falling back to EXLA")
      apply(module_for(:exla), load_fun(role), [config])
  catch
    :exit, _ ->
      Logger.warning("EMLX backend exited for #{inspect(role)}, falling back to EXLA")
      apply(module_for(:exla), load_fun(role), [config])

    :throw, _ ->
      Logger.warning("EMLX backend threw for #{inspect(role)}, falling back to EXLA")
      apply(module_for(:exla), load_fun(role), [config])
  end

  def load(%{backend: backend} = config, role) do
    apply(backend, load_fun(role), [config])
  end

  defp load_fun(:embedding), do: :load_embedding
  defp load_fun(:llm), do: :load_llm
end
