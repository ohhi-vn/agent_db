defmodule AgentDb.Runtime do
  @moduledoc false

  # The composition root's one decision: which provider each port is answered
  # by.
  #
  # Resolved once here rather than per call, so every workflow reaches the same
  # storage and the same models, and a provider can be chosen for a test or an
  # integration without any workflow knowing it. `AgentDb.Application` resolves
  # the same values when it builds the supervision tree, so the tree and the
  # calls cannot disagree about who is serving.
  #
  # The defaults are this project's own adapters, so a deployment that
  # configures nothing behaves exactly as before.
  #
  # Inference has one key rather than one per layer. `:inference_provider` names
  # both what serves `embed/1` and what status reports, because two keys is how
  # a deployment ends up serving Ollama while its own console claims it runs
  # local models. A key that maps to no provider is a configuration error and
  # raises here, rather than falling back to a default nobody asked for.
  #
  # ## The vector index is admitted through here, and contained
  #
  # A vector index is a native engine: sqlite-vec is a loadable extension, and
  # anything that follows it will be a NIF. Both can raise. A raise inside a
  # `GenServer.call` is not an error a caller can act on -- it is an exit, and
  # the process that dies is whichever one the operator was already relying on.
  # `erl_crash.dump` from 2026-10-13 records exactly this shape: an
  # `ArgumentError` raised inside a `GenServer.call` whose *error printer* then
  # died on a closed `standard_error`, taking the runtime down during boot. The
  # diagnostic for the original error died with it.
  #
  # So the three vector functions below are the one place an index answer is
  # admitted into the rest of the store, and they convert every failure mode
  # into the store's existing contract: an error tuple carrying a
  # classification, never an exception, and never a new failure class. They live
  # beside the resolution rather than in its own module so that a workflow
  # naming `Runtime` is still naming the only seam it is allowed to.

  alias AgentDb.Config
  alias AgentDb.Core

  @storage_adapter :storage_adapter
  @inference_adapter :inference_adapter
  @transport_adapter :transport_adapter

  @providers %{
    local: AgentDb.Adapters.Inference,
    ollama: AgentDb.Adapters.Inference.Ollama,
    openai_compatible: AgentDb.Adapters.Inference.OpenAICompatible
  }

  @defaults %{
    storage_adapter: AgentDb.Adapters.SQLite,
    transport_adapter: AgentDb.Adapters.Phoenix
  }

  @ports [
    {@storage_adapter, Core.Storage},
    {@inference_adapter, Core.Inference},
    {@transport_adapter, Core.Transport}
  ]

  @doc "The module answering the storage port."
  @spec storage() :: module()
  def storage, do: adapter(@storage_adapter)

  @doc "The module answering the inference port."
  @spec inference() :: module()
  def inference, do: adapter(@inference_adapter)

  @doc "The module answering the transport port."
  @spec transport() :: module()
  def transport, do: adapter(@transport_adapter)

  # -- the vector index, admitted and contained --

  @doc """
  Nearest neighbours of a query embedding, or a contained failure.

  Containment converts a raise or an exit from inside the engine into the one
  classification a caller already knows how to handle. A classified error is
  passed through as the provider wrote it, so `:dim_mismatch` stays a refusal
  and `{:invalid_dim, _}` stays an invalid query.
  """
  @spec vector_search(binary(), pos_integer(), String.t() | nil, [atom()] | nil) ::
          {:ok, [map()]} | {:error, term()}
  def vector_search(query, top_k, scope_prefix, fields \\ nil) do
    admit(fn -> storage().search_vector(query, top_k, scope_prefix, fields) end)
  end

  @doc "Stores a generated embedding, or a contained failure."
  @spec vector_put(integer(), String.t(), binary()) ::
          {:ok, :stored | :discarded} | {:error, term()}
  def vector_put(job_id, uri, embedding) do
    admit(fn -> storage().put_embedding_result(job_id, uri, embedding) end)
  end

  @doc "Coverage of the index, or a contained failure."
  @spec vector_stats() :: {:ok, map()} | {:error, term()}
  def vector_stats do
    admit(fn -> storage().vector_index_stats() end)
  end

  @doc """
  How many index rows name a URI the store no longer holds, or a contained
  failure.

  Drift is a cost rather than a defect, so this is reported rather than acted
  on here: a caller that wants to reclaim it says so explicitly.
  """
  @spec vector_reclaimable() :: {:ok, non_neg_integer()} | {:error, term()}
  def vector_reclaimable do
    admit(fn -> storage().vector_index_reclaimable() end)
  end

  @doc """
  The module answering `key`.

  `:inference_adapter` is derived from `Config.inference_provider/0` rather than
  configured in its own right: the provider is what a deployment names, and the
  module is only how this runtime reaches it.
  """
  @spec adapter(atom()) :: module()
  def adapter(@inference_adapter), do: inference_module(Config.inference_provider())
  def adapter(key), do: Application.get_env(:agent_db, key) || Map.fetch!(@defaults, key)

  # A provider is named either by one of this project's kinds or by a module
  # implementing the port. Anything else is a typo or a value from a newer
  # version, and guessing a default for it would answer with local models while
  # the deployment believes it configured something else.
  defp inference_module(provider) do
    case @providers do
      %{^provider => module} ->
        module

      %{} ->
        # A custom provider is named by the module itself, so an atom is only
        # accepted when it is a loadable module. A typo is an atom too, and
        # treating it as a module would fail later with "could not load module"
        # instead of naming what is wrong with the configuration.
        if is_atom(provider) and not is_nil(provider) and Code.ensure_loaded?(provider) do
          provider
        else
          raise ArgumentError, """
          #{inspect(provider)} is configured as :inference_provider but names no known provider.

          expected one of: #{inspect(Map.keys(@providers))}, or a module implementing #{inspect(Core.Inference)}
          """
        end
    end
  end

  @doc """
  Fails fast on a provider that cannot answer its port.

  A module that is missing, or that supplies only part of a contract, is a
  deployment error. Substituting the default for it would hide the mistake
  behind a store that quietly serves from somewhere other than where it was
  told to, so this raises at startup instead, where the configuration can still
  be corrected.
  """
  @spec validate!() :: :ok
  def validate! do
    Enum.each(@ports, fn {key, port} ->
      module = adapter(key)
      missing = missing_callbacks(module, port)

      if missing != [] do
        raise ArgumentError, """
        #{inspect(module)} is configured as :#{key} but does not implement #{inspect(port)}.

        missing: #{Enum.map_join(missing, ", ", &format_callback/1)}
        """
      end
    end)

    validate_numeric_config!()

    :ok
  end

  defp validate_numeric_config! do
    workers = Config.job_workers()

    unless is_integer(workers) and workers > 0 do
      raise ArgumentError, "job_workers must be a positive integer, got: #{inspect(workers)}"
    end

    grace = Config.shutdown_grace_ms()

    unless is_integer(grace) and grace >= 0 do
      raise ArgumentError,
            "shutdown_grace_ms must be a non-negative integer, got: #{inspect(grace)}"
    end

    concurrency = Config.inference_concurrency()

    unless is_integer(concurrency) and concurrency > 0 do
      raise ArgumentError,
            "inference_concurrency must be a positive integer, got: #{inspect(concurrency)}"
    end

    :ok
  end

  defp missing_callbacks(module, port) do
    Code.ensure_loaded!(module)

    port.behaviour_info(:callbacks)
    |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp format_callback({name, arity}), do: "#{name}/#{arity}"

  # The one classification every retryable failure collapses onto, so the
  # taxonomy does not grow a class per engine. An index that cannot be reached
  # right now -- it raised, it is saturated, it is not loaded -- is the same fact
  # to a caller: try again later.
  @vector_index_unavailable :vector_index_unavailable

  # An engine's overload is "try again later", the same fact as unreachable. It
  # must not become a distinct class, which would give the taxonomy a permanent
  # failure for a transient condition. No provider emits `:busy` today; the
  # mapping is here and tested so an engine that reports it is handled by the
  # taxonomy it lands in rather than by a new one.
  defp admit(fun) do
    classify(fun.())
  rescue
    _error -> {:error, @vector_index_unavailable}
  catch
    :exit, _reason -> {:error, @vector_index_unavailable}
  end

  defp classify({:error, :busy}), do: {:error, @vector_index_unavailable}
  defp classify(other), do: other
end
