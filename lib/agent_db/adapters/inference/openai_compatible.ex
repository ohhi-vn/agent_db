defmodule AgentDb.Adapters.Inference.OpenAICompatible do
  @moduledoc false

  # OpenAI-compatible inference provider (`/embeddings`, `/chat/completions`).
  #
  # Credentials come only from config/env and never appear in logs, telemetry,
  # or error payloads: failures return classified reasons with the key
  # redacted by construction (the key is only ever sent as a header).

  @behaviour AgentDb.Core.Inference

  @receive_timeout 10_000

  @impl true
  def child_specs(_opts), do: []

  @impl true
  def embed(texts) when is_list(texts) do
    with {:ok, base} <- base_url() do
      url = String.trim_trailing(base, "/") <> "/embeddings"
      headers = auth_headers()

      case Req.post(url, json: %{input: texts}, headers: headers, receive_timeout: @receive_timeout) do
        {:ok, %Req.Response{status: 200, body: %{"data" => items}}} ->
          {:ok, Enum.map(items, fn %{"embedding" => vec} -> encode(vec) end)}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Req.Response{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:inference_failed, status}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, {:inference_timeout, reason}}

        {:error, reason} ->
          {:error, {:inference_failed, reason}}
      end
    end
  rescue
    e -> {:error, {:inference_failed, e}}
  catch
    :exit, reason -> {:error, {:inference_timeout, reason}}
    _, reason -> {:error, {:inference_failed, reason}}
  end

  @impl true
  def summarize(prompt, _opts) when is_binary(prompt) do
    with {:ok, base} <- base_url() do
      url = String.trim_trailing(base, "/") <> "/chat/completions"
      headers = auth_headers()

      body = %{messages: [%{role: "user", content: prompt}]}

      case Req.post(url, json: body, headers: headers, receive_timeout: @receive_timeout) do
        {:ok, %Req.Response{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
          if String.trim(text || "") == "", do: {:error, :empty_summary}, else: {:ok, text}

        {:ok, %Req.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Req.Response{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:inference_failed, status}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, {:inference_timeout, reason}}

        {:error, reason} ->
          {:error, {:inference_failed, reason}}
      end
    end
  rescue
    e -> {:error, {:inference_failed, e}}
  catch
    :exit, reason -> {:error, {:inference_timeout, reason}}
    _, reason -> {:error, {:inference_failed, reason}}
  end

  @impl true
  def model_status do
    %{
      embedding: %{loaded: false, state: :idle, model: "openai-compatible", dim: 1536, provider: :openai_compatible},
      llm: %{loaded: false, state: :idle, model: "openai-compatible", params: "remote", provider: :openai_compatible},
      queue: %{pending: 0},
      provider: :openai_compatible
    }
  end

  defp base_url do
    case AgentDb.Config.openai_compatible_base_url() do
      nil -> {:error, :no_provider_url}
      "" -> {:error, :no_provider_url}
      base -> {:ok, base}
    end
  end

  defp auth_headers do
    case AgentDb.Config.openai_api_key() do
      nil -> []
      "" -> []
      key -> [{"authorization", "Bearer " <> key}]
    end
  end

  defp encode(vec) when is_list(vec) do
    for x <- vec, into: <<>>, do: <<x::float-32>>
  end
end
