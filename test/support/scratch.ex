defmodule AgentDb.Test.Scratch do
  @moduledoc """
  A temporary directory for one test, unique across runs.

  `:erlang.unique_integer/1` counts from zero in every VM, so `mix test`
  starting a new VM replays the same sequence: a run that left
  `agent_db_source_1447/link-staging/` behind makes the next run's first
  symlink test fail with "file already exists", and it fails
  non-deterministically, because it depends on what the previous run reached.

  Each directory is therefore salted with the wall clock and the VM's own
  identity. A collision would need two runs creating a directory in the same
  nanosecond with the same hash, and a stale directory from an earlier run can
  never be reused.

  The suite's cleanup of stale `agent_db_*` directories stays, because a
  directory that is never cleaned up is still a directory that fills `/tmp`.
  """

  @doc "A fresh, uniquely named directory under the system temporary directory."
  @spec dir(String.t()) :: String.t()
  def dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{name}_#{:erlang.unique_integer([:positive])}_#{System.system_time(:native)}_#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(path)
    path
  end
end
