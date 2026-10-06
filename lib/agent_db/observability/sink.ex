defmodule AgentDb.Observability.Sink do
  @moduledoc """
  Holds the store's recent failures and outcome counts, so an operator can see
  what has been going wrong without tailing a log.

  The store's telemetry events were already fire-and-forget: emitted, then
  forgotten, with nothing left in the process that could read them back. This is
  the one thing that keeps them, and it keeps them as bounded counts plus a
  bounded ring -- never a growing history, and never anything the measurements
  were not already allowed to carry.

  It is a process for exactly one reason: ETS needs an owner, and the owner has
  to be somewhere the rest of the store already supervises. The table is public
  and only this module writes to it, so the `:telemetry` handler runs in the
  emitting process and a console reading it never queues behind a worker.
  """

  use GenServer

  @table :agent_db_observability

  # Enough to see a failure as it happens, without turning diagnostics into a
  # second store that grows for as long as the process runs.
  @max_errors 50

  @events [
    [:agent_db, :operation, :stop],
    [:agent_db, :job, :stop],
    [:agent_db, :model, :stop]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec max_errors() :: pos_integer()
  def max_errors, do: @max_errors

  @impl GenServer
  def init(_opts) do
    _tid = create_table()
    :ok = attach()

    {:ok, %{}}
  end

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :named_table,
          :public,
          {:read_concurrency, true},
          {:write_concurrency, true},
          heir: self()
        ])

      tid ->
        tid
    end
  end

  defp attach do
    case :telemetry.attach_many(handler_id(), @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      # Already attached: a restart of this process reattaching to the same
      # events is not a failure worth refusing to start over.
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(handler_id())

  @doc false
  # Runs in whichever process emitted the event. Every operation here is
  # atomic and non-blocking, so a saturated sink delays nothing: a console
  # reading diagnostics cannot slow a write down.
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    record(event, measurements, metadata)
  end

  defp record([:agent_db, family, _stop], measurements, metadata) do
    outcome = Map.get(metadata, :outcome, :ok)

    count(family, dimension(metadata), outcome)
    if outcome == :error, do: remember(family, metadata, measurements)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp record(_event, _measurements, _metadata), do: :ok

  # Only what the event already labels: operation, kind, and role, each of which
  # is named by the code that emits it, so the number of counters follows the
  # store's code rather than its traffic. Nothing here ever adds a URI or an
  # identity to a dimension -- a counter keyed by one would be unbounded by
  # construction.
  #
  # The subset is used as the counter's own dimension, unconverted. Normalizing
  # it into a sorted list of strings looked tidier and cost more than the rest of
  # the handler put together: this runs on every measurement the store emits,
  # including one per node in a tree projection.
  defp dimension(metadata) do
    metadata
    |> Map.take([:operation, :kind, :role])
    |> Map.new(fn {k, v} -> {k, if(is_atom(v), do: v, else: :unknown)} end)
  end

  defp count(family, dimension, outcome) do
    key = {:count, family, dimension, outcome}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Only failures are kept, and only what the measurement already carried: an
  # error a caller cannot act on is noise, and one naming a URI would be a leak.
  defp remember(family, metadata, measurements) do
    seq = System.unique_integer([:positive, :monotonic])

    entry = %{
      family: family,
      operation: Map.get(metadata, :operation) || Map.get(metadata, :kind),
      role: Map.get(metadata, :role),
      reason: Map.get(metadata, :reason) || :error,
      duration_ms: Map.get(measurements, :duration_ms),
      at: System.system_time(:millisecond)
    }

    :ets.insert(@table, {{:error, seq}, entry})
    trim(seq)
  end

  # One indexed pass, not a scan of the table per failure.

  # The sequence numbers are monotonic, so everything older than the newest
  # `@max_errors` can be selected away by a single comparison. Collecting the
  # table to count it instead would be quadratic in the failure rate, and the
  # failure rate is not something this store controls: a projection that lists
  # every node in a subtree asks each document for children it does not have,
  # and each of those is an error event.
  defp trim(seq) do
    cutoff = seq - @max_errors

    if cutoff > 0 do
      :ets.select_delete(@table, [
        {{{:error, :"$1"}, :_}, [{:"=<", :"$1", cutoff}], [true]}
      ])
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp tab2list do
    :ets.tab2list(@table)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc false
  @spec recent_errors(pos_integer()) :: [map()]
  def recent_errors(limit \\ 20) do
    entries = for({{:error, _seq}, entry} <- tab2list(), do: entry)

    entries
    |> Enum.sort_by(& &1.at, :desc)
    |> Enum.take(limit)
  end

  @doc false
  @spec counts() :: map()
  def counts do
    for {{:count, family, dimension, outcome}, value} <- tab2list(),
        into: %{},
        do: {{family, dimension, outcome}, value}
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp handler_id, do: "agent-db-observability-sink"
end
