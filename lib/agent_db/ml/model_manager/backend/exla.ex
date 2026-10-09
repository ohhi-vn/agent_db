defmodule AgentDb.ML.ModelManager.Backend.Exla do
  @moduledoc """
  Bumblebee + EXLA backend (CPU by default, CUDA/ROCm when configured).

  Holds the logic previously inline in `ModelManager`: model loading through
  `BumblebeeLoader` and inference through the stored serving.
  """

  @behaviour AgentDb.ML.ModelManager.Backend

  alias AgentDb.Observability

  @impl true
  def load_embedding(config), do: load_model(config, config.embedding_model, :embedding)

  @impl true
  def load_llm(config), do: load_model(config, config.llm_model, :llm)

  # The serving L2-normalizes during the run (`embedding_processor` in
  # `build_serving/4`), so each tensor is already the unit vector the vector
  # index stores. The serving reports it under `:embedding`; the store's
  # contract is a bare list of tensors.
  @impl true
  def embed(model_ref, texts) do
    with {:ok, result} <- run(model_ref, texts) do
      embeddings =
        result
        |> List.wrap()
        |> Enum.map(fn
          %{embedding: embedding} -> embedding
          tensor -> tensor
        end)

      {:ok, embeddings}
    end
  end

  @impl true
  def summarize(model_ref, prompt, _opts) do
    # Generation length comes from the serving's own configuration rather than
    # from the call, which is why the options are not read here.
    formatted = String.replace(model_ref.chat_template, "%{prompt}", prompt)

    with {:ok, result} <- run(model_ref, formatted),
         {:ok, text} <- text(result) do
      strip_reasoning(text)
    end
  end

  # A serving built from several inputs answers with the per-input list, one
  # text from the first result.
  defp text(%{results: [%{text: text} | _]}), do: {:ok, text}
  defp text([%{text: text} | _]), do: {:ok, text}
  defp text(%{text: text}), do: {:ok, text}
  defp text(_other), do: {:error, {:empty_summary, :no_answer}}

  defp run(model_ref, input) do
    case model_ref.runner.run(model_ref.serving, input) do
      {:ok, result} -> {:ok, result}
      {:error, _} = err -> err
    end
  end

  defp load_model(config, model_id, role) do
    loader = config.loader
    repository = {:hf, model_id}

    with {:ok, tokenizer} <- loader.load_tokenizer(repository),
         {:ok, model_info} <- loader.load_model(repository, backend: config.exla_backend),
         {:ok, serving} <- build_serving(loader, role, model_info, tokenizer, model_id) do
      {:ok,
       %{
         tokenizer: tokenizer,
         model_info: model_info,
         serving: serving,
         runner: loader,
         chat_template: config.llm_chat_template,
         backend: :exla
       }}
    else
      {:error, reason} ->
        Observability.log(:error,
          component: :model,
          operation: :load,
          role: role,
          outcome: :error,
          reason: reason
        )

        {:error, wrap(reason)}

      unexpected ->
        Observability.log(:error,
          component: :model,
          operation: :load,
          role: role,
          outcome: :error,
          reason: {:model_load_failed, :unexpected}
        )

        {:error, wrap(unexpected)}
    end
  rescue
    error ->
      Observability.log(:error,
        component: :model,
        operation: :load,
        role: role,
        outcome: :error,
        reason: {:model_load_failed, :raised}
      )

      {:error, wrap(error)}
  catch
    :exit, reason ->
      Observability.log(:error,
        component: :model,
        operation: :load,
        role: role,
        outcome: :error,
        reason: {:model_load_failed, :exit}
      )

      {:error, wrap({:exit, reason})}

    :throw, value ->
      Observability.log(:error,
        component: :model,
        operation: :load,
        role: role,
        outcome: :error,
        reason: {:model_load_failed, :throw}
      )

      {:error, wrap({:throw, value})}
  end

  # The generation config is read from the same repository as the weights, which
  # the loader knows and a model_info map does not carry.
  defp build_serving(loader, role, model_info, tokenizer, model_id) do
    model_info = Map.put(model_info, :repository, {:hf, model_id})

    loader.build_serving(role, model_info, tokenizer, generation_config())
  end

  # Generation settings are fixed when the serving is built rather than per call:
  # Bumblebee bakes them into the serving. The only caller passes the same
  # values, so nothing is lost and one serving serves every summarization.
  defp generation_config,
    do: [max_new_tokens: 256, temperature: 0.7, top_p: 0.9, batch_size: 1]

  defp wrap({:download_failed, _} = r), do: r
  defp wrap({:model_not_found, _} = r), do: r
  defp wrap(reason), do: {:model_load_failed, reason}

  defp strip_reasoning(text) do
    text
    |> remove_reasoning_segment()
    |> case do
      "" -> {:error, {:empty_summary, :no_answer}}
      summary -> {:ok, summary}
    end
  end

  defp remove_reasoning_segment(text) do
    case String.split(text, "<think>", parts: 2) do
      [_only] -> text
      [_r, rest] -> after_think(rest)
    end
    |> String.trim()
  end

  defp after_think(rest) do
    case String.split(rest, "</think>", parts: 2) do
      [_unterminated] -> ""
      [_r, answer] -> answer
    end
  end
end
