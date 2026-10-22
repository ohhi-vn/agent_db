defmodule AgentDb.Cache do
  @moduledoc false

  # The store's read cache, and the only thing that has to be told when the
  # store changes.
  #
  # Two ETS tables, owned by this process and disposable: correctness never
  # depends on what they hold. A miss is answered from the store and cached; a
  # write drops the entries it affects rather than refreshing them, so the next
  # read rebuilds from what the store actually committed and the cache can
  # never be ahead of it.
  #
  # Consolidating the tables, the lookups and the invalidation into one module
  # is what makes that guarantee checkable: whoever writes has one function to
  # call, and whoever reads has one cache to reason about.

  use GenServer

  @node_cache :agent_db_node_cache
  @dir_cache :agent_db_dir_cache
  @stats_cache :agent_db_cache_stats

  # How many node entries the cache holds before evicting the least recently
  # used one. A bounded cache keeps a runaway read from turning into a
  # runaway memory footprint.
  @max_node_entries 128

  # -- lifecycle --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Public tables: any process reads and writes an entry without a round
    # trip. The heir is this process, so they survive a helper's crash and come
    # back empty if the owner itself goes.
    :ok = create(@node_cache)
    :ok = create(@dir_cache)
    :ok = create_stats()
    {:ok, %{}}
  end

  defp create(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:ordered_set, :named_table, :public, read_concurrency: true, heir: self()])
      :ok
    else
      :ok
    end
  end

  defp create_stats do
    if :ets.whereis(@stats_cache) == :undefined do
      :ets.new(@stats_cache, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true,
        heir: self()
      ])
    end

    for key <- [:node_hits, :node_misses, :dir_hits, :dir_misses] do
      :ets.insert_new(@stats_cache, {key, 0})
    end

    :ok
  end

  # -- reading --

  @doc "A cached node, or `:miss`."
  @spec get_node(String.t()) :: {:ok, term()} | :miss
  def get_node(uri) do
    case lookup_node(uri) do
      {:ok, value} ->
        record_hit(:node)
        touch_node(uri)
        {:ok, value}

      :miss ->
        record_miss(:node)
        :miss
    end
  end

  @doc "A cached directory listing, or `:miss`."
  @spec get_dir(String.t()) :: {:ok, term()} | :miss
  def get_dir(uri) do
    case lookup_dir(uri) do
      {:ok, value} ->
        record_hit(:dir)
        {:ok, value}

      :miss ->
        record_miss(:dir)
        :miss
    end
  end

  @doc "Caches a node."
  @spec put_node(String.t(), term()) :: :ok
  def put_node(uri, node) do
    :ets.insert(@node_cache, {uri, {node, next_seq()}})
    evict_node_if_needed()
    :ok
  end

  @doc "Caches a directory listing."
  @spec put_dir(String.t(), term()) :: :ok
  def put_dir(uri, names) do
    :ets.insert(@dir_cache, {uri, names})
    :ok
  end

  # -- invalidation --

  @doc """
  Drops everything a write at `uri` can have made stale: the node itself, its
  parent's listing, and every ancestor's.
  """
  @spec invalidate_write(String.t()) :: :ok
  def invalidate_write(uri) do
    segments = split(uri)

    drop_node(uri)
    drop_dir(parent_uri(segments))
    Enum.each(ancestors(segments), &drop_dir/1)
  end

  @doc """
  Drops everything a removal at `uri` can have made stale: everything a write
  would, plus the subtree beneath it.
  """
  @spec invalidate_removal(String.t()) :: :ok
  def invalidate_removal(uri) do
    invalidate_write(uri)
    drop_dir(uri)
    drop_beneath(prefix_of(uri))
  end

  defp drop_node(uri), do: :ets.delete(@node_cache, uri)
  defp drop_dir(uri), do: :ets.delete(@dir_cache, uri)

  # Removed subtree entries are the cached keys under the URI, not a second
  # database query: the cache is small, and it is the cache that has to be
  # right about what it no longer holds.
  defp drop_beneath(nil), do: :ok

  defp drop_beneath(prefix) do
    Enum.each(matching_keys(@node_cache, prefix), &drop_node/1)
    Enum.each(matching_keys(@dir_cache, prefix), &drop_dir/1)
  end

  defp matching_keys(table, prefix) do
    case :ets.whereis(table) do
      :undefined ->
        []

      _ ->
        upper = next_prefix(prefix)

        spec =
          if upper == nil do
            [{{:"$1", :_}, [{:>=, :"$1", prefix}], [:"$1"]}]
          else
            [{{:"$1", :_}, [{:>=, :"$1", prefix}, {:<, :"$1", upper}], [:"$1"]}]
          end

        try do
          :ets.select(table, spec)
        rescue
          _ -> []
        catch
          _, _ -> []
        end
    end
  end

  defp next_prefix(prefix) when is_binary(prefix) do
    bytes = :binary.bin_to_list(prefix)

    case List.pop_at(bytes, -1) do
      {nil, _} ->
        nil

      {last, rest} when last < 255 ->
        :binary.list_to_bin(rest ++ [last + 1])

      {_last, rest} ->
        next_prefix(:binary.list_to_bin(rest))
    end
  end

  # -- whole-cache operations --

  @doc "Empties both tables."
  @spec clear() :: :ok
  def clear do
    clear_table(@node_cache)
    clear_table(@dir_cache)
    reset_counters()
    :ok
  end

  defp reset_counters do
    for key <- [:node_hits, :node_misses, :dir_hits, :dir_misses] do
      if :ets.whereis(@stats_cache) != :undefined do
        :ets.insert(@stats_cache, {key, 0})
      end
    end

    :ok
  end

  @doc "Entry counts, for diagnostics and tests."
  @spec stats() :: %{node_cache: non_neg_integer(), dir_cache: non_neg_integer()}
  def stats do
    %{node_cache: size(@node_cache), dir_cache: size(@dir_cache)}
  end

  @doc """
  Entry counts and bytes per table, for an operator telling a grown cache from
  a grown store.

  Bytes are the table's own reported memory rather than the size of what it
  holds, so a large content entry and a small one cost the same to count --
  which is the point: this says how much the cache costs, not what it says.
  """
  @spec detailed_stats() :: map()
  def detailed_stats do
    node_hits = counter(:node_hits)
    node_misses = counter(:node_misses)
    dir_hits = counter(:dir_hits)
    dir_misses = counter(:dir_misses)

    %{
      node_cache: table_stats(@node_cache, node_hits, node_misses),
      dir_cache: table_stats(@dir_cache, dir_hits, dir_misses),
      total_entries: size(@node_cache) + size(@dir_cache),
      total_bytes: bytes(@node_cache) + bytes(@dir_cache),
      hits: node_hits + dir_hits,
      misses: node_misses + dir_misses,
      hit_rate: hit_rate(node_hits + dir_hits, node_misses + dir_misses)
    }
  end

  defp table_stats(table, hits, misses) do
    %{
      entries: size(table),
      bytes: bytes(table),
      hits: hits,
      misses: misses,
      hit_rate: hit_rate(hits, misses)
    }
  end

  defp counter(key) do
    case :ets.whereis(@stats_cache) do
      :undefined ->
        0

      _ ->
        case :ets.lookup(@stats_cache, key) do
          [{^key, value}] -> value
          _ -> 0
        end
    end
  end

  defp hit_rate(_hits, 0), do: 0.0
  defp hit_rate(hits, misses), do: hits / (hits + misses)

  defp bytes(table) do
    case :ets.whereis(table) do
      :undefined -> 0
      _tid -> :ets.info(table, :memory)
    end
  end

  @doc "The bound on the node cache's entry count."
  @spec max_node_entries() :: pos_integer()
  def max_node_entries, do: @max_node_entries

  @doc "The table a node entry lives in."
  @spec node_cache() :: atom()
  def node_cache, do: @node_cache

  @doc "Alias for the node cache's entry bound."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_node_entries

  @doc "The directory table's name."
  @spec dir_cache() :: atom()
  def dir_cache, do: @dir_cache

  defp clear_table(table) do
    if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    :ok
  end

  defp size(table) do
    case :ets.whereis(table) do
      :undefined -> 0
      _tid -> :ets.info(table, :size)
    end
  end

  defp lookup_node(key) do
    case :ets.lookup(@node_cache, key) do
      [{^key, {value, _seq}}] -> {:ok, value}
      [] -> :miss
    end
  end

  defp lookup_dir(key) do
    case :ets.lookup(@dir_cache, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  defp touch_node(uri) do
    case :ets.lookup(@node_cache, uri) do
      [{^uri, {value, _}}] ->
        :ets.insert(@node_cache, {uri, {value, next_seq()}})

      _ ->
        :ok
    end
  end

  defp next_seq do
    System.unique_integer([:positive, :monotonic])
  end

  defp evict_node_if_needed do
    if size(@node_cache) > @max_node_entries do
      case :ets.tab2list(@node_cache) do
        [] ->
          :ok

        entries ->
          {lru_uri, _} = Enum.min_by(entries, fn {_uri, {_value, seq}} -> seq end)
          :ets.delete(@node_cache, lru_uri)
      end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp record_hit(:node), do: :ets.update_counter(@stats_cache, :node_hits, 1, {:node_hits, 0})
  defp record_hit(:dir), do: :ets.update_counter(@stats_cache, :dir_hits, 1, {:dir_hits, 0})

  defp record_miss(:node),
    do: :ets.update_counter(@stats_cache, :node_misses, 1, {:node_misses, 0})

  defp record_miss(:dir), do: :ets.update_counter(@stats_cache, :dir_misses, 1, {:dir_misses, 0})

  # -- URI shapes --

  @doc "The segments of a `viking://` URI."
  @spec split(String.t()) :: [String.t()]
  def split("viking://" <> rest) do
    case String.split(rest, "/", trim: true) do
      [] -> []
      segments -> segments
    end
  end

  defp prefix_of("viking://" <> rest) do
    case rest do
      "" -> nil
      _ -> "viking://" <> rest <> "/"
    end
  end

  defp parent_uri([]), do: nil
  defp parent_uri(segments), do: "viking://" <> (segments |> Enum.drop(-1) |> Enum.join("/"))

  # Every proper prefix of the segment list, the tree root included: those are
  # the listings a write at this URI can have changed.
  defp ancestors(segments) do
    count = length(segments)

    for take <- (count - 1)..0//-1 do
      case Enum.take(segments, take) do
        [] -> "viking://"
        prefix -> "viking://" <> Enum.join(prefix, "/")
      end
    end
  end
end
