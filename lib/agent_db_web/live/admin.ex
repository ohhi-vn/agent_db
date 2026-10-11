defmodule AgentDbWeb.Admin do
  @moduledoc """
  The shared behavior of a console page.

  The console is several pages, but it is one console: every page reaches the
  store through `AgentDbWeb.Context`, and every page that shows live state
  follows the same lifecycle -- subscribe to the tree root on connect, coalesce
  bursts of change events, keep a periodic refresh as a fallback, and reload the
  page's own sections. That lifecycle lives here once, so it cannot drift between
  pages.

  A page does `use AgentDbWeb.Admin`, sets `@admin_page` to the nav entry it
  belongs to, and implements `load/1` (its live sections), `render/1`, and any
  `handle_event/3` clauses its forms need. `mount/3`, `handle_params/3`, and
  `handle_info/2` are provided and overridable.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]

  @refresh_ms 30_000
  # Bursts (e.g. a bulk import publishing one event per change) reload at most
  # once per window; every event still lands in the feed.
  @coalesce_ms 1_000
  @feed_max 20

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView, layout: {AgentDbWeb.Layouts, :admin}

      import Phoenix.LiveView
      import Phoenix.Component

      alias AgentDbWeb.Context

      @before_compile AgentDbWeb.Admin

      @impl Phoenix.LiveView
      def mount(_params, _session, socket),
        do: {:ok, AgentDbWeb.Admin.connect(__MODULE__, socket)}

      @impl Phoenix.LiveView
      def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

      @impl Phoenix.LiveView
      def handle_info(message, socket) do
        AgentDbWeb.Admin.handle_info(__MODULE__, message, socket)
      end

      # The sections this page shows. A page overrides this; the default loads
      # nothing, so a page that owns only operator working state is complete.
      def load(socket), do: socket

      defoverridable mount: 3, handle_params: 3, handle_info: 2, load: 1
    end
  end

  defmacro __before_compile__(env) do
    active = Module.get_attribute(env.module, :admin_page)

    quote do
      @doc false
      def admin_page, do: unquote(active)
    end
  end

  @doc false
  def connect(page, socket) do
    if connected?(socket) do
      # The root is an ancestor of every change, so one subscription sees all
      # writes, removals, replacements and commits. Process-scoped: it ends
      # with this LiveView and is re-established on reconnect.
      _ = AgentDb.subscribe("viking://")
      :timer.send_interval(@refresh_ms, self(), :refresh)
    end

    # Anchored to now rather than zero: the monotonic epoch is arbitrary (it
    # is negative on some machines), so a zero stamp can lie in the future
    # and the first change event would wrongly coalesce instead of reloading.
    last_reload_ms = System.monotonic_time(:millisecond) - @coalesce_ms - 1

    socket
    |> assign(
      active: page.admin_page(),
      recent_changes: [],
      last_reload_ms: last_reload_ms,
      reload_pending: false,
      notice: nil
    )
    |> page.load()
  end

  @doc false
  def handle_info(page, :refresh, socket), do: {:noreply, reload(page, socket)}

  def handle_info(page, :refresh_coalesced, socket), do: {:noreply, reload(page, socket)}

  def handle_info(page, {:context_changed, uri, kind, version}, socket) do
    feed = [%{uri: uri, kind: kind, version: version} | socket.assigns.recent_changes]
    socket = assign(socket, recent_changes: Enum.take(feed, @feed_max))

    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_reload_ms] || 0

    cond do
      socket.assigns[:reload_pending] ->
        {:noreply, socket}

      now - last < @coalesce_ms ->
        Process.send_after(self(), :refresh_coalesced, @coalesce_ms)
        {:noreply, assign(socket, reload_pending: true)}

      true ->
        {:noreply, reload(page, socket)}
    end
  end

  def handle_info(_page, _message, socket), do: {:noreply, socket}

  # A reload refreshes the page's live sections and stamps the time, clearing any
  # pending coalesced reload. Operator working state (search results, import
  # results, session messages) is not loaded by `load/1`, so it survives.
  defp reload(page, socket) do
    socket
    |> page.load()
    |> assign(last_reload_ms: System.monotonic_time(:millisecond), reload_pending: false)
  end
end
