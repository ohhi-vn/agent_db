defmodule AgentDb.Observability do
  @moduledoc """
  Stateless runtime diagnostics: low-cardinality telemetry, distributed traces,
  and redacted structured logs.

  No process, no endpoint, no exporter. `:telemetry` events are always emitted
  locally; OpenTelemetry spans are no-ops unless the host configures an SDK.
  Failures here never replace an operation result.
  """

  require Logger

  @operation_event [:agent_db, :operation, :stop]
  @job_event [:agent_db, :job, :stop]
  @model_event [:agent_db, :model, :stop]

  @doc "Telemetry event names emitted by the store."
  @spec events() :: [[atom()]]
  def events, do: [@operation_event, @job_event, @model_event]

  @doc """
  Runs `fun`, emitting a low-cardinality operation measurement.

  Metadata carries only `operation` and `outcome` (plus `kind`/`role` where
  relevant) — never URIs, content, prompts, users, credentials, or tokens.
  """
  @spec timed(atom(), map(), (-> result)) :: result when result: var
  def timed(operation, meta \\ %{}, fun) when is_atom(operation) and is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      emit_operation(operation, outcome_of(result), start, meta)
      result
    rescue
      error ->
        emit_operation(operation, :error, start, meta)
        reraise error, __STACKTRACE__
    catch
      :exit, reason ->
        emit_operation(operation, :error, start, meta)
        exit(reason)

      :throw, value ->
        emit_operation(operation, :error, start, meta)
        throw(value)
    end
  end

  @doc "Emits a job queue/execution measurement with queue-wait vs execution split."
  @spec emit_job(atom(), :ok | :error | atom(), non_neg_integer(), non_neg_integer()) :: :ok
  def emit_job(kind, outcome, queue_wait_ms, execution_ms) do
    safe_emit(@job_event, %{queue_wait_ms: queue_wait_ms, execution_ms: execution_ms}, %{
      kind: kind,
      outcome: normalize_outcome(outcome)
    })
  end

  @doc "Emits a model load/inference measurement."
  @spec emit_model(atom(), atom(), non_neg_integer()) :: :ok
  def emit_model(role, outcome, duration_ms) do
    safe_emit(@model_event, %{duration_ms: duration_ms}, %{
      role: role,
      outcome: normalize_outcome(outcome)
    })
  end

  @doc """
  Parses a W3C `traceparent` value. Returns `{:ok, %{trace_id, span_id}}` or
  `:error` for missing/malformed input (caller starts a new trace).
  """
  @spec parse_traceparent(String.t() | nil) :: {:ok, map()} | :error
  def parse_traceparent(nil), do: :error
  def parse_traceparent(""), do: :error

  def parse_traceparent(value) when is_binary(value) do
    case String.split(value, "-") do
      [_version, trace_id, span_id, _flags] ->
        if valid_hex?(trace_id, 32) and valid_hex?(span_id, 16) do
          {:ok, %{trace_id: trace_id, span_id: span_id}}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def parse_traceparent(_), do: :error

  @doc "Extracts trace context from HTTP headers or WS event metadata (never rejects)."
  @spec extract_context(map() | keyword() | list()) :: map() | nil
  def extract_context(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"traceparent", value} -> parse_result(value)
      _ -> nil
    end)
  end

  def extract_context(%{"traceparent" => value}), do: parse_result(value)
  def extract_context(%{traceparent: value}), do: parse_result(value)
  def extract_context(%{"opts" => %{"traceparent" => value}}), do: parse_result(value)
  def extract_context(%{opts: %{traceparent: value}}), do: parse_result(value)
  def extract_context(_), do: nil

  @doc "Extracts W3C trace context from a Plug connection (never rejects)."
  @spec from_conn(Plug.Conn.t()) :: map() | nil
  def from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "traceparent") do
      [value | _] -> parse_result(value)
      [] -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "Runs `fun` inside an OTel span when available, otherwise runs directly."
  @spec with_span(String.t(), map(), (-> result)) :: result when result: var
  def with_span(name, attrs \\ %{}, fun) when is_function(fun, 0) do
    if Code.ensure_loaded?(:otel_tracer) and function_exported?(:otel_tracer, :with_span, 3) do
      try do
        apply(:otel_tracer, :with_span, [name, %{attributes: attrs}, fun])
      rescue
        _ -> fun.()
      catch
        _, _ -> fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  Runs a retrieval stage with a bounded OTel span and telemetry measurement.

  Only `stage`, `mode`, and `outcome` are recorded -- never URIs, content,
  prompts, users, or credentials. A missing or malformed parent context
  starts a new trace without changing the result.
  """
  @spec stage(atom(), atom() | nil, (-> result)) :: result when result: var
  def stage(stage_name, mode, fun)
      when is_atom(stage_name) and is_function(fun, 0) do
    attrs = %{stage: stage_name, mode: mode || :unknown}

    with_span("agent_db.#{stage_name}", attrs, fn ->
      timed(stage_name, %{kind: mode || :unknown}, fun)
    end)
  end

  @doc """
  Redacts credentials and secret query params from a URL for logging.
  """
  @spec redact_url(String.t()) :: String.t()
  def redact_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} ->
        redact_query(url)

      %URI{} = uri ->
        uri
        |> Map.put(:userinfo, nil)
        |> Map.update(:query, nil, &redact_params/1)
        |> URI.to_string()
    end
  rescue
    _ -> "[unparseable-url]"
  end

  def redact_url(_), do: "[no-url]"

  @doc "Structured operational log without content, prompts, or credentials."
  @spec log(atom(), keyword()) :: :ok
  def log(level, fields) when level in [:debug, :info, :warning, :error] do
    safe =
      fields
      |> Keyword.take([
        :component,
        :operation,
        :kind,
        :role,
        :outcome,
        :reason,
        :trace_id,
        :job_id
      ])
      |> Keyword.update(:reason, nil, &classify_reason/1)

    try do
      Logger.log(level, "agent_db", safe)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  @doc false
  @spec classify_reason(term()) :: term()
  def classify_reason({:download_failed, _}), do: :download_failed
  def classify_reason({:model_not_found, _}), do: :model_not_found
  def classify_reason({:model_load_failed, _}), do: :model_load_failed
  def classify_reason({:hybrid_leg_timeout, leg}), do: {:hybrid_leg_timeout, leg}
  def classify_reason({:hybrid_leg_failed, leg, _}), do: {:hybrid_leg_failed, leg}
  def classify_reason({:background_jobs_failed, _}), do: :background_jobs_failed
  def classify_reason({:background_jobs_pending, _}), do: :background_jobs_pending
  def classify_reason(:model_loading), do: :model_loading
  def classify_reason(:not_found), do: :not_found
  def classify_reason(:is_root), do: :is_root
  def classify_reason({:invalid_mode, _}), do: :invalid_mode
  def classify_reason(_), do: :error

  defp emit_operation(operation, outcome, start, meta) do
    duration = System.monotonic_time(:millisecond) - start

    safe_meta =
      meta
      |> Map.take([:kind, :role])
      |> Map.merge(%{operation: operation, outcome: normalize_outcome(outcome)})

    safe_emit(@operation_event, %{duration_ms: duration}, safe_meta)
  end

  defp outcome_of(:ok), do: :ok
  defp outcome_of({:ok, _}), do: :ok
  defp outcome_of({:error, _}), do: :error
  defp outcome_of(_), do: :ok

  defp normalize_outcome(:ok), do: :ok
  defp normalize_outcome(:error), do: :error
  defp normalize_outcome({:error, _}), do: :error
  defp normalize_outcome(_), do: :ok

  defp safe_emit(event, measurements, metadata) do
    try do
      :telemetry.execute(event, measurements, metadata)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp parse_result(value) do
    case parse_traceparent(value) do
      {:ok, ctx} -> ctx
      :error -> nil
    end
  end

  defp valid_hex?(value, len) do
    String.length(value) == len and value =~ ~r/\A[0-9a-f]+\z/
  end

  defp redact_query(url) do
    case String.split(url, "?", parts: 2) do
      [base, query] -> base <> "?" <> redact_params(query)
      [base] -> base
    end
  end

  defp redact_params(nil), do: nil

  defp redact_params(query) when is_binary(query) do
    query
    |> URI.decode_query()
    |> Enum.map(fn {k, _v} ->
      if String.contains?(String.downcase(k), ["token", "secret", "key", "auth", "password"]) do
        {k, "[redacted]"}
      else
        {k, "[redacted-param]"}
      end
    end)
    |> URI.encode_query()
  rescue
    _ -> "[redacted]"
  end
end
