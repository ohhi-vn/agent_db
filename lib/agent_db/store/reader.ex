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

  @doc "Checks out a reader connection from the round-robin pool."
  @spec checkout() :: SQLite.conn()
  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  @doc "Runs `fun.(reader_conn)` on a pooled reader connection."
  @spec read((SQLite.conn() -> term())) :: term()
  def read(fun), do: fun.(checkout())

  # -- Server callbacks --

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    count = Keyword.get(opts, :size, System.schedulers_online())

    case open_readers(path, count) do
      {:ok, conns} ->
        {:ok, %{conns: conns, next: 0}}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:checkout, _from, %{conns: conns, next: next} = state) do
    conn = Enum.at(conns, next)
    {:reply, conn, %{state | next: rem(next + 1, length(conns))}}
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
