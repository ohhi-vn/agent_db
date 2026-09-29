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

  alias AgentDb.Core

  @storage_adapter :storage_adapter
  @inference_adapter :inference_adapter
  @transport_adapter :transport_adapter

  @defaults %{
    storage_adapter: AgentDb.Adapters.SQLite,
    inference_adapter: AgentDb.Adapters.Inference,
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

  @doc "The configured provider for `key`, or this project's own when none is configured."
  @spec adapter(atom()) :: module()
  def adapter(key) do
    Application.get_env(:agent_db, key) || Map.fetch!(@defaults, key)
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

    :ok
  end

  defp missing_callbacks(module, port) do
    Code.ensure_loaded!(module)

    port.behaviour_info(:callbacks)
    |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp format_callback({name, arity}), do: "#{name}/#{arity}"
end
