defmodule AgentDb.Adapters.Inference.OpenAICompatible do
  @moduledoc false

  # OpenAI-compatible inference provider (`/embeddings`, `/chat/completions`).
  #
  # Credentials come only from config/env and never appear in logs, telemetry,
  # or error payloads: failures return classified reasons with the key
  # redacted by construction (the key is only ever sent as a header).

  @behaviour AgentDb.Core.Inference

  @receive_timeout 10_000

  # Status is asked for on a console timer, so it gets a deadline of its own
  # rather than reusing the one an inference call waits on.
  @health_timeout 1_500

  @impl true
  def child_specs(_opts), do: []

  @impl true
  def embed(texts) when is_list(texts) do
    with {:ok, base} <- base_url() do
      url = String.trim_trailing(base, "/") <> "/embeddings"
      headers = auth_headers()
      model = AgentDb.Config.openai_embed_model()

      case Req.post(url,
             json: %{model: model, input: texts},
             headers: headers,
             receive_timeout: @receive_timeout
           ) do
        {:ok, %Req.Response{status: 200, body: %{"data" => items}}} ->
          vectors = Enum.map(items, fn %{"embedding" => vec} -> encode(vec) end)

          Enum.each(
            vectors,
            &AgentDb.Adapters.Inference.ObservedDim.observe(:openai_compatible, &1)
          )

          {:ok, vectors}

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

      body = %{
        model: AgentDb.Config.openai_llm_model(),
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post(url, json: body, headers: headers, receive_timeout: @receive_timeout) do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => text}} | _]}
         }} ->
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
    health = health()

    %{
      embedding: %{
        loaded: false,
        state: served_state(health),
        model: AgentDb.Config.openai_embed_model(),
        dim: AgentDb.Adapters.Inference.ObservedDim.get(:openai_compatible),
        provider: :openai_compatible
      },
      llm: %{
        loaded: false,
        state: served_state(health),
        model: AgentDb.Config.openai_llm_model(),
        params: "remote",
        provider: :openai_compatible
      },
      provider: :openai_compatible,
      health: health
    }
  end

  # A remote provider holds no local model, so whether it is usable is a fact
  # about reaching it rather than about what this process loaded. Reporting
  # `:idle` for an unreachable endpoint reads as "nothing configured".
  #
  # Probed with its own, much shorter deadline than an inference call, because
  # status is asked for on a console timer and must not hold it. The probe
  # carries the same credentials an inference request would; a credential is
  # only ever sent as a header and never appears in the reported health.
  defp health do
    case base_url() do
      {:ok, base} ->
        url = String.trim_trailing(base, "/") <> "/models"

        case Req.get(url, headers: auth_headers(), receive_timeout: @health_timeout) do
          {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
          # Reachable but refusing us is a different problem from unreachable,
          # and one an operator fixes with a key rather than with a restart.
          {:ok, %Req.Response{status: 401}} -> :unauthorized
          {:ok, %Req.Response{}} -> :unreachable
          _other -> :unreachable
        end

      {:error, _} ->
        :unreachable
    end
  rescue
    _ -> :unreachable
  catch
    _, _ -> :unreachable
  end

  defp served_state(:ok), do: :ready
  defp served_state(_), do: :unreachable

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
