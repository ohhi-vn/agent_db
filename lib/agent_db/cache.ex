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
    {:ok, %{}}
  end

  defp create(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public, read_concurrency: true, heir: self()])
      :ok
    else
      :ok
    end
  end

  # -- reading --

  @doc "A cached node, or `:miss`."
  @spec get_node(String.t()) :: {:ok, term()} | :miss
  def get_node(uri), do: lookup(@node_cache, uri)

  @doc "A cached directory listing, or `:miss`."
  @spec get_dir(String.t()) :: {:ok, term()} | :miss
  def get_dir(uri), do: lookup(@dir_cache, uri)

  @doc "Caches a node."
  @spec put_node(String.t(), term()) :: :ok
  def put_node(uri, node) do
    :ets.insert(@node_cache, {uri, node})
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
    for {key, _value} <- :ets.tab2list(table),
        is_binary(key),
        String.starts_with?(key, prefix),
        do: key
  end

  # -- whole-cache operations --

  @doc "Empties both tables."
  @spec clear() :: :ok
  def clear do
    clear_table(@node_cache)
    clear_table(@dir_cache)
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
    %{
      node_cache: table_stats(@node_cache),
      dir_cache: table_stats(@dir_cache),
      total_entries: size(@node_cache) + size(@dir_cache),
      total_bytes: bytes(@node_cache) + bytes(@dir_cache)
    }
  end

  defp table_stats(table), do: %{entries: size(table), bytes: bytes(table)}

  defp bytes(table) do
    case :ets.whereis(table) do
      :undefined -> 0
      _tid -> :ets.info(table, :memory)
    end
  end

  @doc "The table a node entry lives in."
  @spec node_cache() :: atom()
  def node_cache, do: @node_cache

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

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

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
