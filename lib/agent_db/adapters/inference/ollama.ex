defmodule AgentDb.Adapters.Inference.Ollama do
  @moduledoc false

  # Ollama inference provider behind the `Core.Inference` port.
  #
  # Uses the existing `Req` dependency with bounded timeouts. Timeouts map
  # to `{:error, {:inference_timeout, reason}}`; other failures map to
  # classified `{:error, reason}` without terminating the caller. No
  # credentials are involved, and nothing sensitive is logged.

  @behaviour AgentDb.Core.Inference

  @receive_timeout 10_000

  # Status is asked for on a console timer, so it gets a deadline of its own
  # rather than reusing the one an inference call waits on.
  @health_timeout 1_500

  @impl true
  def child_specs(_opts), do: []

  @impl true
  def embed(texts) when is_list(texts) do
    base = AgentDb.Config.ollama_base_url()
    model = AgentDb.Config.ollama_embed_model()

    with {:ok, vectors} <- embed_all(base, model, texts) do
      {:ok, vectors}
    end
  end

  @impl true
  def summarize(prompt, _opts) when is_binary(prompt) do
    base = AgentDb.Config.ollama_base_url()
    model = AgentDb.Config.ollama_llm_model()
    url = String.trim_trailing(base, "/") <> "/api/generate"

    case Req.post(url,
           json: %{model: model, prompt: prompt, stream: false},
           receive_timeout: @receive_timeout
         ) do
      {:ok, %Req.Response{status: 200, body: %{"response" => text}}} when is_binary(text) ->
        if String.trim(text) == "", do: {:error, :empty_summary}, else: {:ok, text}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:inference_failed, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:inference_timeout, reason}}

      {:error, reason} ->
        {:error, {:inference_failed, reason}}
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
        model: AgentDb.Config.ollama_embed_model(),
        dim: AgentDb.Adapters.Inference.ObservedDim.get(:ollama),
        provider: :ollama
      },
      llm: %{
        loaded: false,
        state: served_state(health),
        model: AgentDb.Config.ollama_llm_model(),
        params: "remote",
        provider: :ollama
      },
      provider: :ollama,
      health: health
    }
  end

  # A remote provider holds no local model, so whether it is usable is a fact
  # about reaching it rather than about what this process loaded. Reporting
  # `:idle` for an unreachable server reads as "nothing configured"; reporting
  # the failure is what tells an operator their inference is not going to work.
  #
  # The probe is deliberately given a much shorter deadline than an inference
  # request: status is asked for by a console on a timer and must not hold it
  # for the length of a real request timeout.
  defp health do
    url = String.trim_trailing(AgentDb.Config.ollama_base_url(), "/") <> "/api/tags"

    case Req.get(url, receive_timeout: @health_timeout) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{}} -> :unreachable
      _other -> :unreachable
    end
  rescue
    _ -> :unreachable
  catch
    _, _ -> :unreachable
  end

  defp served_state(:ok), do: :ready
  defp served_state(_), do: :unreachable

  defp embed_all(_base, _model, []), do: {:ok, []}

  defp embed_all(base, model, texts) do
    url = String.trim_trailing(base, "/") <> "/api/embed"

    case try_batch(url, model, texts) do
      {:ok, vectors} ->
        observe_all(vectors)
        {:ok, vectors}

      {:error, :batch_rejected} ->
        case embed_one_by_one(url, model, texts) do
          {:ok, vectors} ->
            observe_all(vectors)
            {:ok, vectors}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, {:inference_failed, e}}
  catch
    :exit, reason -> {:error, {:inference_timeout, reason}}
    _, reason -> {:error, {:inference_failed, reason}}
  end

  # One batched call preserving input order. A server that does not accept a
  # list input rejects the batch; that rejection is a fallback signal, not a
  # failure, so it returns `:batch_rejected` for the caller to retry per-text.
  defp try_batch(url, model, texts) do
    case Req.post(url, json: %{model: model, input: texts}, receive_timeout: @receive_timeout) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => vecs}}}
      when is_list(vecs) and length(vecs) == length(texts) ->
        {:ok, Enum.map(vecs, &encode/1)}

      {:ok, %Req.Response{status: 200, body: %{"embedding" => vec}}}
      when length(texts) == 1 ->
        {:ok, [encode(vec)]}

      {:ok, %Req.Response{status: status}} when status in [400, 404, 422] ->
        {:error, :batch_rejected}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :batch_rejected}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:inference_failed, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:inference_timeout, reason}}

      {:error, reason} ->
        {:error, {:inference_failed, reason}}
    end
  end

  defp embed_one_by_one(url, model, texts) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case Req.post(url, json: %{model: model, input: text}, receive_timeout: @receive_timeout) do
        {:ok, %Req.Response{status: 200, body: %{"embeddings" => [vec | _]}}} ->
          {:cont, {:ok, [encode(vec) | acc]}}

        {:ok, %Req.Response{status: 200, body: %{"embedding" => vec}}} ->
          {:cont, {:ok, [encode(vec) | acc]}}

        {:ok, %Req.Response{status: status}} ->
          {:halt, {:error, {:inference_failed, status}}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:halt, {:error, {:inference_timeout, reason}}}

        {:error, reason} ->
          {:halt, {:error, {:inference_failed, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp observe_all(vectors) do
    Enum.each(vectors, &AgentDb.Adapters.Inference.ObservedDim.observe(:ollama, &1))
  end

  defp encode(vec) when is_list(vec) do
    for x <- vec, into: <<>>, do: <<x::float-32>>
  end
end
