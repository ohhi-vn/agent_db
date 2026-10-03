defmodule AgentDb.HexDocs do
  @moduledoc false

  # Hex ecosystem docs as ordinary versioned context documents.
  #
  # Discovery reads `mix.lock` offline and never guesses versions. Each
  # locked package maps to `viking://resources/hex/<package>/<version>/`,
  # holding README/HexDocs/API entries as searchable documents. Ranking
  # prefers the locked version; old versions stay readable until removed.

  @hex_root "viking://resources/hex"

  @doc "Discovers locked Hex packages from `mix.lock` without network."
  @spec discover(String.t()) :: {:ok, [%{package: String.t(), version: String.t()}]}
  def discover(lock_path \\ "mix.lock") do
    case File.read(lock_path) do
      {:ok, content} ->
        {:ok, parse_lock(content)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Docs subtree for a package version."
  @spec docs_uri(String.t(), String.t()) :: String.t()
  def docs_uri(package, version), do: "#{@hex_root}/#{package}/#{version}"

  @doc """
  How much of the locked Hex documentation the store actually holds.

  `packages` is how many packages have documents under their root,
  `documents` how many documents those are, and `locked` how many packages
  `mix.lock` pins. The gap between `locked` and `packages` is what an operator
  needs: a store holding three of its forty dependencies' docs is not one that
  documents its dependencies.

  Discovery is offline and every count is a bounded lookup, so this is safe to
  call from a console that refreshes on a timer.
  """
  @spec coverage() :: %{
          locked: non_neg_integer(),
          packages: non_neg_integer(),
          documents: non_neg_integer()
        }
  def coverage do
    storage = AgentDb.Runtime.storage()

    %{
      locked: locked_count(),
      packages: covered_packages(storage),
      documents: storage.document_count("#{@hex_root}/")
    }
  end

  defp locked_count do
    {:ok, packages} = discover()
    length(packages)
  end

  # One listing plus one count per package, so the cost follows the number of
  # documented packages rather than the size of the store.
  defp covered_packages(storage) do
    case storage.list_children("#{@hex_root}/") do
      {:ok, names} ->
        Enum.count(
          names,
          &match?({:ok, n} when n > 0, storage.document_count("#{@hex_root}/#{&1}"))
        )

      {:error, _} ->
        0
    end
  end

  @doc "Ingests README/API stubs for locked packages as ordinary documents."
  @spec ingest([%{package: String.t(), version: String.t()}]) ::
          {:ok, %{indexed: [String.t()]}} | {:error, term()}
  def ingest(packages) when is_list(packages) do
    indexed =
      Enum.flat_map(packages, fn %{package: pkg, version: ver} ->
        base = docs_uri(pkg, ver)

        docs = %{
          "#{base}/README.md" => "# #{pkg} #{ver}\n\nLocked Hex package #{pkg} at #{ver}.",
          "#{base}/api.md" => "API for #{pkg} #{ver}.\n\nPublic modules and functions."
        }

        Enum.flat_map(docs, fn {uri, content} ->
          case AgentDb.write(uri, content) do
            :ok -> [uri]
            {:error, _} -> []
          end
        end)
      end)

    {:ok, %{indexed: indexed}}
  end

  @doc "Searches Hex docs, preferring `locked` versions first."
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    locked = Keyword.get(opts, :locked, %{})
    scope = Keyword.get(opts, :scope, @hex_root)

    with {:ok, results} <-
           AgentDb.search(query,
             mode: :keyword,
             scope: scope,
             top_k: Keyword.get(opts, :top_k, 20)
           ) do
      {:ok, rank(results, locked)}
    end
  end

  @doc "Reorders results so locked-version URIs outrank other versions."
  @spec rank([map()], map()) :: [map()]
  def rank(results, locked) when is_list(results) and is_map(locked) do
    Enum.sort_by(results, fn result ->
      case version_of(result[:uri] || result["uri"] || "") do
        {pkg, ver} ->
          if Map.get(locked, pkg) == ver, do: 0, else: 1

        _ ->
          1
      end
    end)
  end

  defp version_of("viking://resources/hex/" <> rest) do
    case String.split(rest, "/") do
      [pkg, ver | _] -> {pkg, ver}
      _ -> :unknown
    end
  end

  defp version_of(_), do: :unknown

  defp parse_lock(content) do
    case Code.eval_string(content) do
      {lock, _} when is_map(lock) ->
        Enum.flat_map(lock, fn
          {pkg, tuple} when is_binary(pkg) and is_tuple(tuple) ->
            case Tuple.to_list(tuple) do
              [:hex, _name, version | _] when is_binary(version) ->
                [%{package: pkg, version: version}]

              _ ->
                []
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
