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
  def load_embedding(config), do: load(config, :embedding, config.embedding_model)

  @impl true
  def load_llm(config), do: load(config, :llm, config.llm_model)

  # The serving is built from the same model_info EXLA builds it from, so both
  # backends run identical inference; only the backend the weights were placed
  # on differs, which the rewrite below applies to.
  defp load(config, role, model_id) do
    with :ok <- ensure_available() do
      loader = config.loader

      with {:ok, tokenizer} <- loader.load_tokenizer({:hf, model_id}),
           {:ok, model_info} <- loader.load_model({:hf, model_id}, backend: emlx_backend_spec()),
           {:ok, serving} <- build_serving(loader, role, model_info, tokenizer, model_id) do
        {:ok,
         %{
           tokenizer: tokenizer,
           model_info: maybe_rewrite(model_info),
           serving: serving,
           runner: loader,
           chat_template: config.llm_chat_template,
           backend: :emlx
         }}
      else
        {:error, reason} ->
          Logger.warning("EMLX #{role} load failed, falling back: #{inspect(reason)}")
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

  defp build_serving(loader, role, model_info, tokenizer, model_id) do
    model_info = Map.put(model_info, :repository, {:hf, model_id})
    loader.build_serving(role, model_info, tokenizer, generation_config())
  end

  defp generation_config, do: [max_new_tokens: 256, temperature: 0.7, top_p: 0.9, batch_size: 1]

  @impl true
  def embed(model_ref, texts), do: Exla.embed(model_ref, texts)

  @impl true
  def summarize(model_ref, prompt, opts), do: Exla.summarize(model_ref, prompt, opts)

  defp emlx_backend_spec, do: :emlx

  # The rewrite applies to the Axon model inside the model_info, which is what
  # the serving is later built from.
  defp maybe_rewrite(model_info) do
    if Code.ensure_loaded?(EMLXAxon) and function_exported?(EMLXAxon, :rewrite, 1) do
      try do
        Map.update!(model_info, :model, &apply(EMLXAxon, :rewrite, [&1]))
      rescue
        _ -> model_info
      catch
        _, _ -> model_info
      end
    else
      model_info
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
