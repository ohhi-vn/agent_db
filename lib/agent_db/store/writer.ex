defmodule AgentDb.Store.Writer do
  @moduledoc false

  # Single writer process: owns the only SQLite write connection and serializes
  # every write. Readers use their own connections (see AgentDb.Store).
  # All database mutation funs run in this process via GenServer.call.

  use GenServer
  alias AgentDb.Store.SQLite

  @type write_fun :: (SQLite.conn() -> {:ok, term()} | {:error, term()} | term())

  # -- Client API --

  # Every write carries an explicit, bounded timeout: a caller that omits one
  # gets the default rather than GenServer.call's five-second default, and a
  # write that exceeds its bound reports a retryable classified error instead
  # of taking the caller down with it.
  @default_timeout 30_000

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
    GenServer.call(__MODULE__, {:write, fun}, timeout || @default_timeout)
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

  # A busy write is retried with a growing delay inside a bounded budget.
  # Exhausting the budget reports a retryable classified error rather than a
  # single fixed-delay retry that re-runs the callback once.
  @max_busy_retries 5
  @busy_base_ms 10
  @busy_max_ms 200

  defp run_with_busy_retry(fun, conn), do: run_with_busy_retry(fun, conn, 0)

  defp run_with_busy_retry(fun, conn, attempt) do
    case run_callback(fun, conn) do
      {:error, _} = err when is_tuple(err) ->
        if busy_error?(err) and attempt < @max_busy_retries do
          delay = min(@busy_max_ms, @busy_base_ms * Integer.pow(2, attempt)) + :rand.uniform(20)
          Process.sleep(delay)
          run_with_busy_retry(fun, conn, attempt + 1)
        else
          if busy_error?(err), do: {:error, :storage_busy}, else: err
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
