defmodule AgentDb.Cache.Invalidate do
  @moduledoc false

  # Invalidation-on-write: after a successful persist, drop cache entries so
  # subsequent reads repopulate from SQLite. Invalidation covers the written
  # node, its parent dir entry, and every ancestor dir entry (D3). We
  # deliberately drop (not refresh) entries: the next read rebuilds from
  # SQLite, which guarantees cache == cold-cache-from-disk after any write.

  alias AgentDb.Cache.Owner

  @doc """
  Invalidates all cache state affected by a write at `uri`:
  the node entry, parent dir entry, and all ancestor dir entries.
  """
  @spec on_write(String.t()) :: :ok
  def on_write(uri) do
    segments = split(uri)

    Owner.drop_node(uri)
    Owner.drop_dir(parent_uri(segments))

    segments
    |> ancestors()
    |> Enum.each(&Owner.drop_dir/1)

    :ok
  end

  @doc "Invalidates all cache state affected by removing the subtree at `uri`."
  @spec on_rm(String.t()) :: :ok
  def on_rm(uri) do
    on_write(uri)
    Owner.drop_dir(uri)
    drop_subtree_entries(prefix_of(uri))
    :ok
  end

  defp prefix_of("viking://" <> rest) do
    case rest do
      "" -> nil
      _ -> "viking://" <> rest <> "/"
    end
  end

  # Removed subtree node entries: any node_cache key whose uri starts with
  # "uri/" is inside the deleted subtree. dir_cache entries under it are
  # likewise inside. We scan the small set of cached keys rather than SQLite.
  defp drop_subtree_entries(nil), do: :ok

  defp drop_subtree_entries(prefix) do
    subtree_node_keys =
      :ets.tab2list(Owner.node_cache())
      |> Enum.flat_map(fn
        {key, _} when is_binary(key) ->
          if String.starts_with?(key, prefix), do: [key], else: []

        _ ->
          []
      end)

    Enum.each(subtree_node_keys, &Owner.drop_node/1)

    subtree_dir_keys =
      :ets.tab2list(Owner.dir_cache())
      |> Enum.flat_map(fn
        {key, _} when is_binary(key) ->
          if String.starts_with?(key, prefix), do: [key], else: []

        _ ->
          []
      end)

    Enum.each(subtree_dir_keys, &Owner.drop_dir/1)
    :ok
  end

  @doc "Splits a viking:// URI into its segment list."
  @spec split(String.t()) :: [String.t()]
  def split("viking://" <> rest) do
    case String.split(rest, "/", trim: true) do
      [] -> []
      segs -> segs
    end
  end

  defp parent_uri(segments)

  defp parent_uri([]), do: nil

  defp parent_uri([_ | _] = segments) do
    "viking://" <> Enum.join(Enum.drop(segments, -1), "/")
  end

  # Ancestor dir keys: every proper prefix of the segment list that is a dir
  # entry. For ["resources", "p", "docs", "a.md"], dir entries exist for
  # "viking://resources/p" and "viking://resources" (the tree root "viking://"
  # is cached under the literal key "viking://").
  defp ancestors(segments) do
    n = length(segments)

    for k <- (n - 1)..0//-1 do
      case Enum.take(segments, k) do
        [] -> "viking://"
        prefix -> "viking://" <> Enum.join(prefix, "/")
      end
    end
  end
end
