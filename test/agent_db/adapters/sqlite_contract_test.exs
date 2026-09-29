defmodule AgentDb.Adapters.SQLiteContractTest do
  @moduledoc """
  The default storage provider, held to the storage contract.

  The same suite runs against any provider, so what it asserts is what a
  provider owes rather than what this one happens to do.
  """
  use AgentDb.StorageContract, async: false

  @impl AgentDb.StorageContract
  def storage, do: AgentDb.Adapters.SQLite

  @doc """
  Takes the job queue away, so a write that reaches it fails after everything
  before it has been done, and puts it back afterwards.

  The table is renamed rather than dropped, so what was already queued for a URI
  is still there to be counted: the failure has to come from the write being
  attempted, not from the store losing the rows that were there before.
  """
  @impl AgentDb.StorageContract
  def break_writes do
    rename("ALTER TABLE job_queue RENAME TO job_queue_missing")

    fn -> rename("ALTER TABLE job_queue_missing RENAME TO job_queue") end
  end

  defp rename(statement) do
    AgentDb.Store.Writer.call(fn conn -> AgentDb.Store.SQLite.exec(conn, statement) end)
  end

  storage_contract()
end
