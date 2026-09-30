defmodule AgentDb.Application.Sessions do
  @moduledoc false

  # Sessions: an ordered list of messages, and committing one into the tree as a
  # document.
  #
  # A session is the only part of the store that is a conversation rather than
  # a place things are filed, and committing is the moment it becomes part of
  # what the agent can read back.

  alias AgentDb.Cache
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @type id :: String.t()
  @type message :: %{seq: non_neg_integer(), role: atom(), content: String.t()}

  @doc "Creates a session and returns its id."
  @spec create() :: {:ok, id()} | {:error, term()}
  def create, do: Runtime.storage().create_session()

  @doc "Appends a message to a session, preserving order."
  @spec append_message(id(), atom(), String.t()) :: :ok | {:error, term()}
  def append_message(session_id, role, content) do
    Runtime.storage().append_message(session_id, role, content)
  end

  @doc "Every message of a session, in order."
  @spec get(id()) :: {:ok, [message()]} | {:error, term()}
  def get(session_id), do: Runtime.storage().get_session(session_id)

  @doc "Ids of every session, ordered."
  @spec list_ids() :: {:ok, [id()]} | {:error, term()}
  def list_ids, do: Runtime.storage().list_session_ids()

  @doc """
  Restores a session with its original id and messages in order.

  Creates the session when absent; reports `{:ok, :skipped}` when it already
  holds exactly these messages; reports `{:error, {:session_conflict, id}}`
  and writes nothing when it holds different messages.
  """
  @spec restore(id(), [message()]) :: {:ok, :imported | :skipped} | {:error, term()}
  def restore(session_id, messages) when is_binary(session_id) and is_list(messages) do
    Runtime.storage().restore_session(session_id, messages)
  end

  @doc """
  Commits a session into the tree at `destination_uri` as one document.

  Idempotent per (session, destination): committing a session whose messages
  have not changed reports `{:ok, :unchanged}` and rewrites nothing. The
  decision is based on the conversation's content rather than on a recorded
  hash alone -- if the destination has been removed, its bookkeeping went with
  it, so the commit rebuilds the document instead of reporting it unchanged.

  Options:
    - `:formatter` - how to render messages into a document
  """
  @spec commit(id(), String.t(), keyword()) :: {:ok, String.t() | :unchanged} | {:error, term()}
  def commit(session_id, destination_uri, opts \\ []) do
    with {:ok, []} <- VikingURI.parse(destination_uri) do
      {:error, :is_root}
    else
      {:ok, _segments} -> write_commit(session_id, destination_uri, opts)
      {:error, _} = err -> err
    end
  end

  defp write_commit(session_id, destination_uri, opts) do
    with {:ok, messages} <- get(session_id) do
      case converged?(Runtime.storage(), session_id, destination_uri, messages) do
        true ->
          # SQLite was left untouched, so the cache already agrees with it and
          # dropping it would only force a needless rebuild.
          {:ok, :unchanged}

        false ->
          persist(session_id, destination_uri, messages, opts)
      end
    end
  end

  # The hash covers the rendered conversation rather than the raw message list,
  # so a change in how a session is rendered is a change in what the commit
  # produced, and is written rather than reported as unchanged.
  defp converged?(storage, session_id, destination_uri, messages) do
    case storage.commit_hash(session_id, destination_uri) do
      {:ok, hash} -> hash == digest(messages)
      {:error, _} = err -> err
    end
  end

  defp persist(session_id, destination_uri, messages, opts) do
    hash = digest(messages)
    content = Keyword.get(opts, :formatter, &transcript/1).(messages)

    case Runtime.storage().put_commit(session_id, destination_uri, hash, content) do
      :ok ->
        # A real commit rewrote the document, so a warm cache would otherwise
        # keep serving what was there before it.
        Cache.invalidate_write(destination_uri)
        {:ok, destination_uri}

      {:error, _} = err ->
        err
    end
  end

  defp digest(messages) do
    messages
    |> Enum.sort_by(& &1.seq)
    |> Enum.map_join("\n", fn message -> "#{message.role}: #{message.content}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # One message per paragraph, attributed: a committed conversation has to read
  # as a conversation when it is read back.
  defp transcript(messages) do
    messages
    |> Enum.sort_by(& &1.seq)
    |> Enum.map_join("\n\n", fn message -> "#{message.role}: #{message.content}" end)
  end
end
