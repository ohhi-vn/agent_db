defmodule AgentDb.Store.Sessions do
  @moduledoc false

  # Session table operations over a SQLite connection. Pure functions: the caller
  # supplies the connection (writer for mutations, reader for queries).

  alias AgentDb.Store.SQLite

  @type message :: %{seq: integer(), role: atom(), content: String.t()}

  @doc "Creates a session and returns its id."
  @spec create(SQLite.conn()) :: {:ok, String.t()} | {:error, term()}
  def create(conn) do
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    now = System.system_time(:millisecond)

    case SQLite.exec_write(conn, "INSERT INTO sessions (id, created_at) VALUES (?1, ?2)", [
           session_id,
           now
         ]) do
      :ok -> {:ok, session_id}
      {:error, _} = err -> err
    end
  end

  @doc "Appends a message to a session, preserving order."
  @spec append(SQLite.conn(), String.t(), atom(), String.t()) :: :ok | {:error, term()}
  def append(conn, session_id, role, content) do
    with {:ok, seq} <- next_seq(conn, session_id) do
      SQLite.exec_write(
        conn,
        "INSERT INTO session_messages (session_id, seq, role, content) VALUES (?1, ?2, ?3, ?4)",
        [session_id, seq, to_string(role), content]
      )
    end
  end

  @doc "Every message of a session, in order."
  @spec read(SQLite.conn(), String.t()) :: {:ok, [message()]} | {:error, term()}
  def read(conn, session_id) do
    case SQLite.query(
           conn,
           "SELECT seq, role, content FROM session_messages WHERE session_id = ?1 ORDER BY seq LIMIT 1000",
           [session_id]
         ) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [seq, role, content] ->
           %{seq: seq, role: role(role), content: content}
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc "Ids of every session, ordered."
  @spec list_ids(SQLite.conn()) :: {:ok, [String.t()]} | {:error, term()}
  def list_ids(conn) do
    case SQLite.query(conn, "SELECT id FROM sessions ORDER BY id LIMIT 500", []) do
      {:ok, rows} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Restores a session with a specific id and its messages in order.

  Creates the session when absent and appends the messages. When the session
  already holds exactly these messages (compared as `{role, content}` pairs in
  order) it reports `{:ok, :skipped}` and writes nothing. When it holds
  different messages it reports `{:error, {:session_conflict, id}}` and leaves
  the stored session untouched, so an import never silently overwrites a live
  conversation.
  """
  @spec restore(SQLite.conn(), String.t(), [message()]) ::
          {:ok, :imported | :skipped} | {:error, term()}
  def restore(conn, session_id, messages) when is_binary(session_id) and is_list(messages) do
    with {:ok, existing} <- read(conn, session_id) do
      cond do
        same_messages?(existing, messages) -> {:ok, :skipped}
        existing != [] -> {:error, {:session_conflict, session_id}}
        true -> insert_restored(conn, session_id, messages)
      end
    end
  end

  @doc """
  Maps a stored role back to the atom the store writes.

  A role is only ever one this store wrote, so an unknown value is a corrupt
  row rather than a caller-supplied atom to be created on the spot: it travels
  on unchanged so the worker can fail it as an invalid kind instead.
  """
  @spec role(String.t() | atom()) :: atom() | String.t()
  def role(role) when is_atom(role), do: role
  def role("user"), do: :user
  def role("assistant"), do: :assistant
  def role("system"), do: :system
  def role(other), do: other

  defp next_seq(conn, session_id) do
    case SQLite.query_one(conn, "SELECT MAX(seq) FROM session_messages WHERE session_id = ?1", [
           session_id
         ]) do
      {:ok, [nil]} -> {:ok, 0}
      {:ok, [n]} -> {:ok, n + 1}
      {:ok, []} -> {:ok, 0}
      {:error, _} = err -> err
    end
  end

  defp same_messages?(existing, incoming) do
    Enum.map(existing, &{&1.role, &1.content}) ==
      Enum.map(incoming, &{role(&1.role), &1.content})
  end

  defp insert_restored(conn, session_id, messages) do
    now = System.system_time(:millisecond)

    with :ok <-
           SQLite.exec_write(
             conn,
             "INSERT OR IGNORE INTO sessions (id, created_at) VALUES (?1, ?2)",
             [
               session_id,
               now
             ]
           ) do
      Enum.reduce_while(Enum.with_index(messages), :ok, fn {message, seq}, :ok ->
        case SQLite.exec_write(
               conn,
               "INSERT INTO session_messages (session_id, seq, role, content) VALUES (?1, ?2, ?3, ?4)",
               [session_id, seq, to_string(role(message.role)), message.content]
             ) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        :ok -> {:ok, :imported}
        {:error, _} = err -> err
      end
    end
  end
end
