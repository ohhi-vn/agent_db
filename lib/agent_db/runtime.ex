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
end
