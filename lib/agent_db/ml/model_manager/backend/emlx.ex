defmodule AgentDb.ML.ModelManager.Backend.Emlx do
  @moduledoc """
  Apple MLX backend (EMLX + EMLXAxon).

  Loads the same HuggingFace repositories through Bumblebee but onto the
  `EMLX.Backend` Nx backend, rewriting LLM graphs with `EMLXAxon` Metal
  shaders when that optional dependency is present. Returns
  `{:error, :emlx_unavailable}` when the platform or dependencies cannot run
  MLX so `ModelManager` can fall back to EXLA.
  """

  @behaviour AgentDb.ML.ModelManager.Backend

  require Logger

  alias AgentDb.ML.ModelManager.Backend.Exla

  @impl true
  def load_embedding(config) do
    with :ok <- ensure_available() do
      loader = config.loader

      with {:ok, tokenizer} <- loader.load_tokenizer({:hf, config.embedding_model}),
           {:ok, %{model: model, spec: spec}} <-
             loader.load_model({:hf, config.embedding_model}, backend: emlx_backend_spec()) do
        {:ok,
         %{
           tokenizer: tokenizer,
           model: model,
           spec: spec,
           serving: loader.serving(:embedding),
           chat_template: config.llm_chat_template,
           backend: :emlx
         }}
      else
        {:error, reason} ->
          Logger.warning("EMLX embedding load failed, falling back: #{inspect(reason)}")
          {:error, reason}

        unexpected ->
          {:error, {:model_load_failed, unexpected}}
      end
    end
  rescue
    error -> {:error, {:emlx_unavailable, error}}
  catch
    :exit, reason -> {:error, {:emlx_unavailable, {:exit, reason}}}
    :throw, value -> {:error, {:emlx_unavailable, {:throw, value}}}
  end

  @impl true
  def load_llm(config) do
    with :ok <- ensure_available() do
      loader = config.loader

      with {:ok, tokenizer} <- loader.load_tokenizer({:hf, config.llm_model}),
           {:ok, %{model: model, spec: spec}} <-
             loader.load_model({:hf, config.llm_model}, backend: emlx_backend_spec()) do
        {:ok,
         %{
           tokenizer: tokenizer,
           model: model |> maybe_rewrite(),
           spec: spec,
           serving: loader.serving(:llm),
           chat_template: config.llm_chat_template,
           backend: :emlx
         }}
      else
        {:error, reason} ->
          Logger.warning("EMLX LLM load failed, falling back: #{inspect(reason)}")
          {:error, reason}

        unexpected ->
          {:error, {:model_load_failed, unexpected}}
      end
    end
  rescue
    error -> {:error, {:emlx_unavailable, error}}
  catch
    :exit, reason -> {:error, {:emlx_unavailable, {:exit, reason}}}
    :throw, value -> {:error, {:emlx_unavailable, {:throw, value}}}
  end

  @impl true
  def embed(model_ref, texts), do: Exla.embed(model_ref, texts)

  @impl true
  def summarize(model_ref, prompt, opts), do: Exla.summarize(model_ref, prompt, opts)

  @impl true
  def model_info, do: %{backend: :emlx}

  defp emlx_backend_spec, do: :emlx

  defp maybe_rewrite(model) do
    if Code.ensure_loaded?(EMLXAxon) and function_exported?(EMLXAxon, :rewrite, 1) do
      try do
        apply(EMLXAxon, :rewrite, [model])
      rescue
        _ -> model
      catch
        _, _ -> model
      end
    else
      model
    end
  end

  defp ensure_available do
    cond do
      not Code.ensure_loaded?(EMLX) -> {:error, :emlx_unavailable}
      not apple_silicon?() -> {:error, :emlx_unavailable}
      true -> :ok
    end
  end

  defp apple_silicon? do
    AgentDb.ML.ModelManager.Backend.apple_silicon?()
  end
end
