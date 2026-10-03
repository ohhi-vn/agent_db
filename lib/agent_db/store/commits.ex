defmodule AgentDb.Store.Commits do
  @moduledoc false

  # Commit bookkeeping over a SQLite connection. Pure functions: the caller
  # supplies the connection (writer for mutations, reader for queries).
  #
  # Keyed by destination URI, never session id alone: a session committed to
  # several destinations loses bookkeeping for the removed one and keeps it for
  # the rest. Leaving a stale row here is what makes a later re-commit of an
  # unchanged session report :unchanged without restoring the document.

  alias AgentDb.Store.SQLite

  @doc "The content hash recorded for a (session, destination) commit, if any."
  @spec hash(SQLite.conn(), String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def hash(conn, session_id, destination_uri) do
    case SQLite.query_one(
           conn,
           "SELECT content_hash FROM commit_meta WHERE session_id = ?1 AND destination_uri = ?2",
           [session_id, destination_uri]
         ) do
      {:ok, [hash]} -> {:ok, hash}
      {:ok, nil} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  @doc "Writes the commit bookkeeping for a committed document."
  @spec record(SQLite.conn(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def record(conn, session_id, destination_uri, hash) do
    SQLite.exec_write(
      conn,
      """
      INSERT INTO commit_meta (session_id, destination_uri, content_hash, committed_at)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(session_id, destination_uri) DO UPDATE SET
        content_hash = excluded.content_hash,
        committed_at = excluded.committed_at
      """,
      [session_id, destination_uri, hash, System.system_time(:millisecond)]
    )
  end
end
