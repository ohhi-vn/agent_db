defmodule AgentDb.Adapters.Inference.ObservedDim do
  @moduledoc false

  # Last observed embedding dim per provider, or `:unknown` before any embed.
  #
  # Backed by `:persistent_term` so a fresh boot reports `:unknown` without any
  # process or table, and every caller reads the same value. Display literals
  # elsewhere are never routing truth; this is the only observed-dim source the
  # status surface reads.

  @spec observe(atom(), binary()) :: :ok
  def observe(provider, embedding) when is_atom(provider) and is_binary(embedding) do
    if rem(byte_size(embedding), 4) == 0 and byte_size(embedding) > 0 do
      :persistent_term.put({__MODULE__, provider}, div(byte_size(embedding), 4))
    end

    :ok
  end

  @spec get(atom()) :: pos_integer() | :unknown
  def get(provider) when is_atom(provider) do
    :persistent_term.get({__MODULE__, provider}, :unknown)
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    for provider <- [:local, :ollama, :openai_compatible] do
      :persistent_term.erase({__MODULE__, provider})
    end

    :ok
  end
end
