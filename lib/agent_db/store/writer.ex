defmodule AgentDb.Store.Writer do
  @moduledoc false

  # Single writer process: owns the only SQLite write connection and serializes
  # every write. Readers use their own connections (see AgentDb.Store).
  # All database mutation funs run in this process via GenServer.call.

  use GenServer
  alias AgentDb.Store.SQLite

  @type write_fun :: (SQLite.conn() -> {:ok, term()} | {:error, term()} | term())

  # -- Client API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs `fun.(write_conn)` on the writer connection. The reply is whatever `fun`
  returns; callers must return ok/error tuples for composable error handling.
  """
  @spec call(write_fun(), non_neg_integer() | nil) :: term()
  def call(fun, timeout \\ nil) do
    case timeout do
      nil -> GenServer.call(__MODULE__, {:write, fun})
      ms -> GenServer.call(__MODULE__, {:write, fun}, ms)
    end
  end

  @doc "Returns the writer connection for read-only fallback use in tests."
  @spec conn() :: SQLite.conn()
  def conn do
    GenServer.call(__MODULE__, :conn)
  end

  # -- Server callbacks --

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    schema? = Keyword.get(opts, :ensure_schema, true)

    with {:ok, conn} <- SQLite.open(path),
         :ok <- maybe_schema(conn, schema?) do
      {:ok, %{conn: conn}}
    else
      {:error, reason} ->
        # The store is the whole application: if its one write connection
        # cannot be opened, or its schema cannot be created, there is nothing
        # left to start and every later failure would report the wrong cause.
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:write, fun}, _from, state) do
    {:reply, run_with_busy_retry(fun, state.conn), state}
  end

  @impl true
  def handle_call(:conn, _from, state) do
    {:reply, state.conn, state}
  end

  defp run_with_busy_retry(fun, conn) do
    case run_callback(fun, conn) do
      {:error, _} = err when is_tuple(err) ->
        if busy_error?(err) do
          Process.sleep(10 + :rand.uniform(40))

          case run_callback(fun, conn) do
            {:error, _} = err2 ->
              if busy_error?(err2), do: {:error, :storage_busy}, else: err2

            other ->
              other
          end
        else
          err
        end

      other ->
        other
    end
  end

  defp run_callback(fun, conn) do
    fun.(conn)
  rescue
    error -> {:error, {:callback_failed, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:callback_failed, kind, reason}}
  end

  defp busy_error?({:error, :storage_busy}), do: true
  defp busy_error?({:error, reason}), do: busy_text?(inspect(reason))

  defp busy_text?(text) do
    down = String.downcase(text)
    String.contains?(down, "busy") or String.contains?(down, "locked")
  end

  defp maybe_schema(_conn, false), do: :ok
  defp maybe_schema(conn, true), do: SQLite.ensure_schema(conn)
end
