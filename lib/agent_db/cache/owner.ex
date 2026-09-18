defmodule AgentDb.Cache.Owner do
  @moduledoc false

  # Owns the two ETS cache tables. Tables are public so any process can read
  # and write cache entries without a GenServer round trip; ownership by this
  # process with `heir: self()` means the tables survive helper crashes and
  # are recreated empty if the owner itself crashes (D7: correctness never
  # depends on cache contents).

  use GenServer

  @tables %{
    node_cache: :agent_db_node_cache,
    dir_cache: :agent_db_dir_cache
  }

  # -- Client API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the node cache table name, creating nothing."
  @spec node_cache() :: atom()
  def node_cache, do: @tables.node_cache

  @doc "Returns the dir cache table name."
  @spec dir_cache() :: atom()
  def dir_cache, do: @tables.dir_cache

  @doc "Reads a node cache entry, or :miss."
  @spec get_node(term()) :: {:ok, term()} | :miss
  def get_node(key) do
    lookup(@tables.node_cache, key)
  end

  @doc "Reads a dir cache entry, or :miss."
  @spec get_dir(term()) :: {:ok, term()} | :miss
  def get_dir(key) do
    lookup(@tables.dir_cache, key)
  end

  @doc "Writes a node cache entry."
  @spec put_node(term(), term()) :: :ok
  def put_node(key, value) do
    :ets.insert(@tables.node_cache, {key, value})
    :ok
  end

  @doc "Writes a dir cache entry."
  @spec put_dir(term(), term()) :: :ok
  def put_dir(key, value) do
    :ets.insert(@tables.dir_cache, {key, value})
    :ok
  end

  @doc "Drops one key from the node cache."
  @spec drop_node(term()) :: :ok
  def drop_node(key) do
    :ets.delete(@tables.node_cache, key)
    :ok
  end

  @doc "Drops one key from the dir cache."
  @spec drop_dir(key :: term()) :: :ok
  def drop_dir(key) do
    :ets.delete(@tables.dir_cache, key)
    :ok
  end

  @doc "Empties both caches."
  @spec clear() :: :ok
  def clear do
    clear_table(@tables.node_cache)
    clear_table(@tables.dir_cache)
    :ok
  end

  defp clear_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(table)
    end
  end

  @doc "Counts entries (diagnostics/tests)."
  @spec stats() :: %{node_cache: non_neg_integer(), dir_cache: non_neg_integer()}
  def stats do
    %{
      node_cache: table_size(@tables.node_cache),
      dir_cache: table_size(@tables.dir_cache)
    }
  end

  defp table_size(table) do
    case :ets.whereis(table) do
      :undefined -> 0
      _ -> :ets.info(table, :size)
    end
  end

  # -- Server callbacks --

  @impl true
  def init(_opts) do
    :ok = create(@tables.node_cache)
    :ok = create(@tables.dir_cache)
    {:ok, %{}}
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  defp create(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public, read_concurrency: true, heir: self()])
      :ok
    else
      :ok
    end
  end
end
