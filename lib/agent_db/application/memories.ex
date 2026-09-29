defmodule AgentDb.Application.Memories do
  @moduledoc false

  # Durable, typed facts an agent holds about its user and its work.
  #
  # A memory is an ordinary document with an assertion behind it, and the
  # assertion -- not the document -- is the memory. That is what makes a
  # revised belief resolvable: the URI says which thing is being asserted, the
  # assertions say what has been held about it, and supersession says which of
  # them is current.
  #
  # No model is involved in any of this. The value of a memory is what it says,
  # and the summaries in this store exist to compress a document too large to
  # read whole; an atomic fact is neither.

  alias AgentDb.Cache
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @type uri :: String.t()
  @type value :: String.t()
  @type type :: String.t()
  @type entry :: %{
          id: integer(),
          uri: uri(),
          value: value(),
          type: type(),
          confidence: float(),
          source: String.t() | nil,
          status: :active | :superseded,
          supersedes: integer() | nil,
          updated_at: integer()
        }

  # Memories live in a reserved subtree, and a memory's type is the first
  # segment beneath it. Deriving the type from the URI rather than accepting it
  # as an option is what keeps a memory an ordinary document: recall by type is
  # then a prefix query, and a memory's stated type can never contradict where
  # it is filed.
  @root ["user", "memories"]
  @types ~w(profile preferences entities events experiences)
  @default_confidence 0.5

  @doc "The memory types, for callers that need to enumerate the taxonomy."
  @spec types() :: [type()]
  def types, do: @types

  @doc "The confidence recorded when a caller supplies none."
  @spec default_confidence() :: float()
  def default_confidence, do: @default_confidence

  @doc """
  Records a durable fact at `uri`, which must sit beneath
  `viking://user/memories/<type>/`.

  The URI is the identity of the thing being asserted, so recording where a
  memory already exists revises it: the prior value is kept as superseded and
  linked to the assertion that replaced it. Recording where nothing exists
  creates it.

  Enqueues embedding generation and no summarization. The embedding is what
  makes a memory reachable by meaning rather than by the words it happens to
  contain; a summary could say nothing about an atomic fact its value does not
  already say.

  Options:
    - `:confidence` - how firmly the fact is held, 0.0..1.0 (default #{@default_confidence})
    - `:source` - provenance, e.g. the originating session id

  Returns `{:ok, uri}`, or an error naming the invalid type
  (`{:error, {:invalid_memory_type, type}}`), a URI outside the memories root
  (`{:error, {:not_a_memory_uri, uri}}`), or `{:error, :invalid_uri}`.
  """
  @spec remember(uri(), value(), keyword()) :: {:ok, uri()} | {:error, term()}
  def remember(uri, value, opts \\ []) when is_binary(value) do
    confidence = Keyword.get(opts, :confidence, @default_confidence)
    source = Keyword.get(opts, :source)

    with {:ok, uri} <- validate_slot(uri),
         :ok <- validate_confidence(confidence),
         :ok <- Runtime.storage().put_memory(uri, value, confidence, source) do
      Cache.invalidate_write(uri)
      Runtime.storage().enqueue_job(:embed, %{uri: uri, content: value})
      {:ok, uri}
    end
  end

  @doc """
  Reads memories back. Accepts a URI directly, or options:

    - `:uri` - recall one memory or a subtree
    - `:type` - recall a whole type, e.g. `:events`
    - `:term` - restrict to memories whose value contains this substring
    - `:include_superseded` - also return superseded assertions, for inspecting
      how a memory's value changed (default `false`)

  `:uri` and `:type` both scope the recall; when both are given `:uri` wins.
  Results are ordered by descending confidence, and a recall matching nothing
  returns `{:ok, []}` rather than an error.

  Each entry carries `:id`, `:uri`, `:value`, `:type`, `:confidence`, `:source`,
  `:status`, `:supersedes` and `:updated_at`. With `include_superseded: true`, a
  superseded entry's `:supersedes` is the `:id` of the assertion that replaced
  it, so the chain can be walked from either end.
  """
  @spec recall(uri() | keyword()) :: {:ok, [entry()]} | {:error, term()}
  def recall(uri_or_opts \\ [])

  def recall(uri) when is_binary(uri), do: recall(uri: uri)

  def recall(opts) when is_list(opts) do
    term = Keyword.get(opts, :term)

    statuses =
      if Keyword.get(opts, :include_superseded, false) do
        [:active, :superseded]
      else
        [:active]
      end

    with {:ok, scope} <- recall_scope(opts) do
      case Runtime.storage().recall_memories(scope, term, statuses) do
        {:ok, rows} -> {:ok, Enum.map(rows, &entry(&1, opts))}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Removes the memory at `uri` along with its provenance: its value, every
  assertion recorded there including superseded ones, and its document.

  Supersession, not forgetting, is what preserves history; a tombstone that
  kept the text would not have forgotten anything. A URI holding only an
  ordinary document is left alone.

  Returns `:ok`, or `{:error, :no_memory}` when no memory is recorded there.
  """
  @spec forget(uri()) :: :ok | {:error, term()}
  def forget(uri) do
    with {:ok, _segments} <- VikingURI.parse(uri) do
      forget_recorded(uri)
    end
  end

  # The same removal any document gets, rather than a memory-specific delete: a
  # memory is an ordinary document with an assertion behind it, and the
  # assertion rows are keyed by URI like everything else. That is what keeps a
  # forgotten memory from leaving text behind.
  defp forget_recorded(uri) do
    case Runtime.storage().memory_recorded?(uri) do
      {:ok, true} -> remove(uri)
      {:ok, false} -> {:error, :no_memory}
      {:error, _} = err -> err
    end
  end

  defp remove(uri) do
    case Runtime.storage().remove_subtree(uri) do
      :ok ->
        Cache.invalidate_removal(uri)
        :ok

      {:error, _} = err ->
        err
    end
  end

  # -- validation --

  defp validate_slot(uri) do
    case VikingURI.parse(uri) do
      {:ok, [_user, "memories", type | rest]} when rest != [] ->
        if type in @types, do: {:ok, uri}, else: {:error, {:invalid_memory_type, type}}

      {:ok, _other} ->
        {:error, {:not_a_memory_uri, uri}}

      {:error, :invalid_uri} ->
        {:error, :invalid_uri}
    end
  end

  defp validate_confidence(confidence) when is_number(confidence) do
    if confidence >= 0.0 and confidence <= 1.0 do
      :ok
    else
      {:error, {:invalid_confidence, confidence}}
    end
  end

  defp validate_confidence(confidence), do: {:error, {:invalid_confidence, confidence}}

  # `:uri` scopes directly and `:type` scopes to that type's subtree; neither
  # scopes to the whole memories root. The store matches a scope as
  # exact-uri-or-descendant, so no trailing separator is involved and a scope of
  # `.../preferences` cannot reach a sibling `preferences-extra`.
  defp recall_scope(opts) do
    case {Keyword.get(opts, :uri), Keyword.get(opts, :type)} do
      {nil, nil} ->
        {:ok, root_uri()}

      {uri, _type} when is_binary(uri) ->
        with :ok <- validate_memory_scope(uri), do: {:ok, uri}

      {nil, type} ->
        with {:ok, type} <- validate_type(type), do: {:ok, root_uri() <> "/" <> type}

      {_uri, type} ->
        # An explicit URI already fixes the scope, so the type only has to be
        # one this store recognises: a typo is reported rather than ignored.
        validate_type(type)
    end
  end

  # A type arrives either as a URI segment or as an option a caller naturally
  # writes as an atom. Both resolve to the segment form, which is what the URI
  # and the taxonomy actually speak.
  defp validate_type(type) when is_atom(type) and not is_nil(type) do
    validate_type(Atom.to_string(type))
  end

  defp validate_type(type) when is_binary(type) do
    if type in @types, do: {:ok, type}, else: {:error, {:invalid_memory_type, type}}
  end

  defp validate_type(type), do: {:error, {:invalid_memory_type, type}}

  defp validate_memory_scope(uri) do
    segments = elem(VikingURI.parse(uri), 1)

    if Enum.take(segments, length(@root)) == @root do
      :ok
    else
      {:error, {:not_a_memory_uri, uri}}
    end
  end

  defp root_uri, do: VikingURI.build(@root)

  # `-- type` is reported rather than stored, because it is a fact about where
  # the memory is filed, and re-deriving it here keeps the reported type from
  # ever disagreeing with the URI.
  defp entry(row, opts) do
    type = type_from(opts[:uri] || row.uri)

    Map.take(row, [:id, :uri, :value, :confidence, :source, :status, :supersedes, :updated_at])
    |> Map.put(:type, type)
  end

  defp type_from(uri) do
    uri |> VikingURI.parse() |> elem(1) |> Enum.at(length(@root))
  end
end
