defmodule AgentDb.RuntimeContext do
  @moduledoc false

  # Read-only BEAM runtime snapshots as queryable context.
  #
  # Captures a point-in-time view without starting, stopping, or messaging
  # application processes. Only bounded dimensions are reported (names,
  # counts, sizes, reductions, mailbox lengths); message bodies, ETS
  # contents, document content, and credentials are never included.
  # Oversized runtimes truncate with `truncated: true` rather than failing.

  @max_processes 100
  @max_ets 50
  @max_apps 100

  @doc "Captures a runtime snapshot for `node()` (or the given node)."
  @spec snapshot(node() | nil) :: {:ok, map()} | {:error, term()}
  def snapshot(node \\ nil) do
    target = node || Node.self()

    if target != Node.self() and Node.ping(target) != :pong do
      {:error, {:node_unreachable, target}}
    else
      {:ok, build(target)}
    end
  rescue
    e -> {:error, {:snapshot_failed, e}}
  catch
    :exit, reason -> {:error, {:snapshot_failed, {:exit, reason}}}
    _, reason -> {:error, {:snapshot_failed, reason}}
  end

  defp build(node) do
    {procs, procs_truncated} = processes()
    {tables, ets_truncated} = ets_tables()

    %{
      node: node,
      captured_at: System.system_time(:millisecond),
      uptime_ms: uptime_ms(),
      applications: applications(),
      supervisors: supervisors(),
      process_counts: %{total: length(Process.list())},
      processes: procs,
      ets: tables,
      memory: memory(),
      schedulers: schedulers(),
      queue_depth: queue_depth(),
      truncated: procs_truncated or ets_truncated
    }
  end

  # How long the VM has been up, which is what separates "this store is new"
  # from "this store has been quietly failing for a week".
  defp uptime_ms do
    :erlang.statistics(:wall_clock) |> elem(0)
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  # `:application.which_applications/0` is the supported call; the `Application`
  # wrapper was never part of the standard library.
  defp applications do
    :application.which_applications()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@max_apps)
    |> Enum.map(fn {app, _desc, vsn} -> %{app: app, vsn: to_string(vsn)} end)
  rescue
    _ -> []
  end

  defp supervisors do
    for pid <- Process.list(),
        {:ok, info} <- [safe_sup_info(pid)],
        info != nil,
        do: info
  end

  defp safe_sup_info(pid) do
    case Process.info(pid, [:registered_name, :current_function]) do
      [{:registered_name, name}, {:current_function, {m, f, a}}] when name != [] ->
        if supervisor_function?({m, f, a}), do: %{pid: inspect(pid), name: name}, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp supervisor_function?({:supervisor, _, _}), do: true
  defp supervisor_function?(_), do: false

  defp processes do
    all = Process.list()

    entries =
      all
      |> Enum.sort()
      |> Enum.take(@max_processes)
      |> Enum.map(fn pid ->
        info =
          Process.info(pid, [:registered_name, :current_function, :reductions, :message_queue_len])

        %{
          pid: inspect(pid),
          name: registered(info),
          current_function: current(info),
          reductions: reductions(info),
          mailbox_len: mailbox(info)
        }
      end)

    {entries, length(all) > @max_processes}
  end

  defp ets_tables do
    all = :ets.all()

    entries =
      all
      |> Enum.sort()
      |> Enum.take(@max_ets)
      |> Enum.flat_map(fn tid ->
        case :ets.info(tid, :name) do
          :undefined -> []
          name -> [%{table: inspect(name), size: table_size(tid)}]
        end
      end)

    {entries, length(all) > @max_ets}
  end

  defp memory do
    %{
      total: :erlang.memory(:total),
      processes: :erlang.memory(:processes),
      ets: :erlang.memory(:ets)
    }
  rescue
    _ -> %{total: 0}
  end

  defp schedulers do
    %{online: System.schedulers_online(), total: System.schedulers()}
  end

  defp queue_depth do
    AgentDb.queue_stats()
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp registered([{:registered_name, name} | _]), do: name
  defp registered(_), do: nil

  defp current([_, {:current_function, mfa} | _]), do: inspect(mfa)
  defp current([{_, _} | rest]), do: current(rest)
  defp current(_), do: nil

  defp reductions(info) do
    case List.keyfind(info, :reductions, 0) do
      {:reductions, n} -> n
      _ -> 0
    end
  end

  defp mailbox(info) do
    case List.keyfind(info, :message_queue_len, 0) do
      {:message_queue_len, n} -> n
      _ -> 0
    end
  end

  defp table_size(tid) do
    case :ets.info(tid, :size) do
      :undefined -> 0
      n when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end
end
