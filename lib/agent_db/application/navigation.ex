defmodule AgentDb.Application.Navigation do
  @moduledoc false

  # Input validation shared by the read-only navigation operations (`find`,
  # `grep`): the query shape, the result bound, and the scope. One definition
  # so the two operations cannot disagree about what a valid request looks
  # like; the bounds stay with the callers, which own their documented
  # defaults and maxima.

  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @doc "A non-empty literal query of at most `max_length` characters."
  @spec validate_query(term(), pos_integer()) :: :ok | {:error, term()}
  def validate_query(query, max_length) when is_binary(query) do
    if String.valid?(query) and String.length(query) >= 1 and
         String.length(query) <= max_length do
      :ok
    else
      {:error, {:invalid_query, query}}
    end
  end

  def validate_query(query, _max_length), do: {:error, {:invalid_query, query}}

  @doc "The `:limit` option, defaulted and bounded."
  @spec validate_limit(keyword(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def validate_limit(opts, default, max) do
    case Keyword.get(opts, :limit, default) do
      limit when is_integer(limit) and limit >= 1 and limit <= max -> {:ok, limit}
      limit -> {:error, {:invalid_limit, limit}}
    end
  end

  # A `nil` scope searches the whole tree. The root searches everything as
  # well, so it needs no existence check. Any other scope must parse and
  # exist, otherwise a typo would silently answer with nothing.
  @doc "The `:scope` option as a validated scope URI, or `nil` for the whole tree."
  @spec validate_scope(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def validate_scope(opts) do
    case Keyword.get(opts, :scope) do
      nil ->
        {:ok, nil}

      uri when is_binary(uri) ->
        with {:ok, segments} <- VikingURI.parse(uri) do
          scope_uri = VikingURI.build(segments)

          if segments == [] do
            {:ok, nil}
          else
            case Runtime.storage().get_node(scope_uri) do
              {:ok, nil} -> {:error, :not_found}
              {:ok, _node} -> {:ok, scope_uri}
              {:error, _} = err -> err
            end
          end
        end

      _other ->
        {:error, :invalid_uri}
    end
  end
end
