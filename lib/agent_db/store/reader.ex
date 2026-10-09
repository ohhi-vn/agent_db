defmodule AgentDb.Store.Reader do
  @moduledoc false

  # Pool of read-only SQLite connections. Readers never block each other and
  # never take the write lock; SQLite WAL allows concurrent readers alongside
  # the single writer.

  use GenServer

  alias AgentDb.Store.SQLite

  @type pool :: [SQLite.conn()]

  # -- Client API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Checks out a reader connection from the pool with an exclusive lease."
  @spec checkout() :: {:ok, SQLite.conn()} | {:error, :storage_busy}
  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  @doc "Returns a reader connection to the pool."
  @spec checkin(SQLite.conn()) :: :ok
  def checkin(conn) do
    GenServer.call(__MODULE__, {:checkin, conn})
  end

  @doc "Runs `fun.(reader_conn)` on a pooled reader connection with checkout/checkin."
  @spec read((SQLite.conn() -> term())) :: term()
  def read(fun) do
    case checkout_with_retry(50) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          checkin(conn)
        end

      {:error, :storage_busy} = err ->
        err
    end
  end

  defp checkout_with_retry(0), do: checkout()

  defp checkout_with_retry(left) do
    case checkout() do
      {:ok, _} = ok ->
        ok

      {:error, :storage_busy} = err ->
        if left > 1 do
          Process.sleep(10)
          checkout_with_retry(left - 1)
        else
          err
        end
    end
  end

  # -- Server callbacks --

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    count = Keyword.get(opts, :size, System.schedulers_online())

    case open_readers(path, count) do
      {:ok, conns} ->
        {:ok, %{available: conns, checked_out: MapSet.new()}}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:checkout, _from, %{available: []} = state) do
    {:reply, {:error, :storage_busy}, state}
  end

  def handle_call(:checkout, _from, %{available: [conn | rest], checked_out: out} = state) do
    {:reply, {:ok, conn}, %{state | available: rest, checked_out: MapSet.put(out, conn)}}
  end

  def handle_call({:checkin, conn}, _from, %{available: avail, checked_out: out} = state) do
    if MapSet.member?(out, conn) do
      out = MapSet.delete(out, conn)
      {:reply, :ok, %{state | available: [conn | avail], checked_out: out}}
    else
      {:reply, :ok, state}
    end
  end

  defp open_readers(path, count) do
    results =
      for _ <- 1..count do
        SQLite.open(path)
      end

    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] ->
        {:ok, Enum.map(results, fn {:ok, conn} -> conn end)}

      [first | _] ->
        Enum.each(results, fn
          {:ok, conn} -> SQLite.close(conn)
          _ -> :ok
        end)

        first
    end
  end
end
