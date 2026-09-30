defmodule AgentDb.ML.ModelManager.Backend.Exla do
  @moduledoc """
  Bumblebee + EXLA backend (CPU by default, CUDA/ROCm when configured).

  Holds the logic previously inline in `ModelManager`: model loading through
  `BumblebeeLoader` and inference through the stored serving.
  """

  @behaviour AgentDb.ML.ModelManager.Backend

  require Logger

  @impl true
  def load_embedding(config), do: load_model(config, config.embedding_model, :embedding)

  @impl true
  def load_llm(config), do: load_model(config, config.llm_model, :llm)

  @impl true
  def embed(model_ref, texts) do
    tokenizer = model_ref.tokenizer
    model = model_ref.model
    serving = model_ref.serving

    with {:ok, inputs} <- serving.tokenize(tokenizer, texts),
         {:ok, outputs} <- serving.generate(model, inputs, &pool/1) do
      embeddings =
        Enum.map(outputs, fn output ->
          tensor = Nx.tensor(output.embedding)
          norm = Nx.sqrt(Nx.sum(Nx.pow(tensor, 2)))
          Nx.divide(tensor, norm)
        end)

      {:ok, embeddings}
    end
  end

  @impl true
  def summarize(model_ref, prompt, opts) do
    tokenizer = model_ref.tokenizer
    model = model_ref.model
    serving = model_ref.serving
    max_tokens = Keyword.get(opts, :max_tokens, 256)
    temperature = Keyword.get(opts, :temperature, 0.7)
    formatted = String.replace(model_ref.chat_template, "%{prompt}", prompt)

    with {:ok, inputs} <- serving.tokenize(tokenizer, formatted),
         {:ok, outputs} <-
           serving.generate(model, inputs, %{
             max_tokens: max_tokens,
             temperature: temperature,
             top_p: 0.9,
             return_probabilities: false
           }) do
      outputs
      |> List.first()
      |> Map.get(:text, "")
      |> strip_reasoning()
    end
  end

  @impl true
  def model_info, do: %{backend: :exla}

  defp pool(embedding), do: Nx.to_flat_list(Nx.mean(embedding, axes: [1]))

  defp load_model(config, model_id, role) do
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
         chat_template: config.llm_chat_template,
         backend: :exla
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to load #{inspect(role)} model: #{inspect(reason)}")
        {:error, wrap(reason)}

      unexpected ->
        Logger.error("Unexpected #{inspect(role)} load result: #{inspect(unexpected)}")
        {:error, wrap(unexpected)}
    end
  rescue
    error ->
      Logger.error("Raised while loading #{inspect(role)} model: #{inspect(error)}")
      {:error, wrap(error)}
  catch
    :exit, reason ->
      Logger.error("Exited while loading #{inspect(role)} model: #{inspect(reason)}")
      {:error, wrap({:exit, reason})}

    :throw, value ->
      Logger.error("Threw while loading #{inspect(role)} model: #{inspect(value)}")
      {:error, wrap({:throw, value})}
  end

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
