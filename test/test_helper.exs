# Clean stale agent_db test dirs from previous runs (unique_integer is per-VM,
# so old runs can leave directories that collide with new ones: a reused
# `agent_db_task_N` dir still holds the previous run's skill files, which the
# importer then reads as part of the new source). Every scratch prefix the
# suite writes under System.tmp_dir!() is covered, not just the data dirs, and
# only entries older than an hour go, so a concurrent run's fresh dirs survive.
stale_cutoff = System.system_time(:second) - 3600

case File.ls(System.tmp_dir!()) do
  {:ok, entries} ->
    entries
    |> Enum.filter(&String.starts_with?(&1, "agent_db_"))
    |> Enum.each(fn dir ->
      path = Path.join(System.tmp_dir!(), dir)

      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} when mtime < stale_cutoff -> File.rm_rf(path)
        _ -> :ok
      end
    end)

  _ ->
    :ok
end

# Shared model-loading fakes and the storage contract suite. Required rather
# than compiled via elixirc_paths so they are available to a single-file
# `mix test path` run as well as the suite.
Code.require_file("support/ml_fakes.ex", __DIR__)
Code.require_file("support/provider_fakes.ex", __DIR__)
Code.require_file("support/storage_contract.ex", __DIR__)
Code.require_file("support/scratch.ex", __DIR__)

ExUnit.start()
