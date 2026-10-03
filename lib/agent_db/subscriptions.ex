defmodule AgentDb.Subscriptions do
  @moduledoc false

  # Reactive context subscriptions over the store's own PubSub.
  #
  # A subscription is a PubSub subscription to the watched URI's topic.
  # A change at a URI publishes to that URI and every ancestor, so a
  # subscriber to an ancestor-or-self scope receives it while a sibling
  # scope (e.g. `project-old` vs `project`) never matches. Delivery is
  # process-scoped and non-durable: PubSub cleans up on exit and restart,
  # pending events are never persisted, and a slow or crashed subscriber
  # never blocks the writer.

  alias AgentDb.URI, as: VikingURI

  @pubsub AgentDb.PubSub
  @versions :agent_db_subscription_versions

  @type kind :: :written | :removed | :replaced | :committed

  @doc "Subscribes the caller to a `viking://` subtree, even one holding nothing yet."
  @spec subscribe(String.t()) :: :ok | {:error, :invalid_uri}
  def subscribe(uri) when is_binary(uri) do
    with {:ok, _} <- VikingURI.parse(uri) do
      ensure_versions()

      try do
        :ok = Phoenix.PubSub.subscribe(@pubsub, topic(uri))
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  def subscribe(_), do: {:error, :invalid_uri}

  @doc "Unsubscribes the caller; always succeeds."
  @spec unsubscribe(String.t()) :: :ok | {:error, :invalid_uri}
  def unsubscribe(uri) when is_binary(uri) do
    with {:ok, _} <- VikingURI.parse(uri) do
      try do
        :ok = Phoenix.PubSub.unsubscribe(@pubsub, topic(uri))
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

      :ok
    end
  end

  def unsubscribe(_), do: {:error, :invalid_uri}

  @doc "Publishes one versioned event per change root to ancestor scopes."
  @spec broadcast(String.t(), kind()) :: :ok
  def broadcast(uri, kind)
      when is_binary(uri) and kind in [:written, :removed, :replaced, :committed] do
    version = next_version(uri)

    for scope <- scopes(uri) do
      try do
        Phoenix.PubSub.broadcast(@pubsub, topic(scope), {:context_changed, uri, kind, version})
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  def broadcast(_, _), do: :ok

  defp topic(uri), do: "agent_db:context:" <> uri

  # The changed URI and every ancestor up to the tree root. A change at
  # `a/b/c` notifies watchers of `a/b/c`, `a/b`, `a`, and the root, and
  # nothing else -- which is what keeps `project-old` from matching
  # `project`.
  defp scopes(uri) do
    case VikingURI.parse(uri) do
      {:ok, []} ->
        [VikingURI.build([])]

      {:ok, segments} ->
        for take <- length(segments)..0//-1, do: VikingURI.build(Enum.take(segments, take))

      {:error, _} ->
        [uri]
    end
  end

  defp ensure_versions do
    if :ets.whereis(@versions) == :undefined do
      try do
        :ets.new(@versions, [:set, :named_table, :public, read_concurrency: true])
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp next_version(uri) do
    ensure_versions()

    try do
      :ets.update_counter(@versions, uri, {2, 1}, {uri, 0})
    rescue
      _ -> System.unique_integer([:monotonic, :positive])
    catch
      _, _ -> System.unique_integer([:monotonic, :positive])
    end
  end
end
