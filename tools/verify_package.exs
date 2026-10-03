# Asserts what a consumer actually receives from the built Hex package.
#
# Run `mix hex.build` first, then:
#
#     mix run --no-start tools/verify_package.exs
#
# The point of inspecting the archive rather than reading `mix.exs` is that the
# declared file list is an intention. This reads the shipped payload, so a file
# that leaked in -- a model cache, a build directory, a local data directory --
# fails here instead of at a consumer's `mix deps.get`.
#
# CI runs the same script, so the assertion that matters is written once.

defmodule AgentDb.VerifyPackage do
  @required ["lib", "config", "priv/static", "docs", "mix.exs", "README.md", "LICENSE"]

  @forbidden [
    # Local state a developer accumulates and must never publish.
    "models",
    "data",
    "_build",
    "deps",
    # Sources that are not needed to run the published library.
    "assets",
    "bench",
    "test",
    "tools",
    "openspec",
    "doc"
  ]

  def run do
    [archive | _] = Path.wildcard("agent_db-*.tar")
    archive || raise("no agent_db-*.tar found; run `mix hex.build` first")

    work =
      Path.join(System.tmp_dir!(), "agent_db_package_check_#{System.unique_integer([:positive])}")

    File.rm_rf!(work)
    File.mkdir_p!(work)

    try do
      {files, metadata} = inspect_package(archive, work)
      report(files, metadata)
    after
      File.rm_rf!(work)
    end
  end

  defp inspect_package(archive, work) do
    extract(archive, work)
    extract(Path.join(work, "contents.tar.gz"), Path.join(work, "contents"))

    extracted = Path.join(work, "contents")
    files = all_files(extracted)
    metadata = read_metadata(Path.join(work, "metadata.config"))

    {files, metadata}
  end

  defp extract(archive, into) do
    File.mkdir_p!(into)

    :ok =
      :erl_tar.extract(String.to_charlist(archive), [
        :compressed,
        {:cwd, String.to_charlist(into)}
      ])
  end

  defp report(files, metadata) do
    extracted = files |> hd() |> Path.dirname()
    missing = Enum.reject(@required, &File.exists?(Path.join(extracted, &1)))
    leaked = Enum.filter(@forbidden, &File.exists?(Path.join(extracted, &1)))
    sidecars = Enum.filter(files, &(Path.basename(&1) =~ ~r/^\._/))
    assets = Path.wildcard(Path.join([extracted, "priv", "static", "**", "*"]))

    problems =
      [
        {missing != [], fn -> "missing from the package: #{Enum.join(missing, ", ")}" end},
        {leaked != [],
         fn -> "local or non-runtime files in the package: #{Enum.join(leaked, ", ")}" end},
        {sidecars != [],
         fn ->
           "#{length(sidecars)} AppleDouble sidecar(s) in the package, first: #{hd(sidecars)}"
         end},
        {assets == [],
         fn -> "priv/static holds no assets, so the console would ship without them" end},
        {incomplete(metadata) != [],
         fn -> "incomplete package identity: #{Enum.join(incomplete(metadata), ", ")}" end}
      ]
      |> Enum.filter(fn {failed?, _message} -> failed? end)
      |> Enum.map(fn {_failed?, message} -> message.() end)

    if problems == [] do
      IO.puts(
        "package ok: #{length(files)} files, identity complete " <>
          "(#{metadata["name"]} #{metadata["version"]}, #{Enum.join(metadata["licenses"], ", ")})"
      )
    else
      Enum.each(problems, &IO.puts(:stderr, "package check failed: " <> &1))
      System.halt(1)
    end
  end

  # The identity a consumer resolves the package by is read from the archive's
  # own metadata, not from `mix.exs`.
  defp incomplete(metadata) do
    for {key, value} <- [
          name: Map.get(metadata, "name"),
          version: Map.get(metadata, "version"),
          description: Map.get(metadata, "description"),
          licenses: Map.get(metadata, "licenses"),
          links: Map.get(metadata, "links"),
          elixir: Map.get(metadata, "elixir")
        ],
        blank?(value),
        do: key
  end

  defp all_files(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(&walk(Path.join(root, &1)))
  end

  defp walk(path) do
    cond do
      File.dir?(path) -> Enum.flat_map(File.ls!(path), &walk(Path.join(path, &1)))
      Path.basename(path) =~ ~r/^\._/ -> [path]
      true -> [path]
    end
  end

  defp read_metadata(path) do
    {:ok, terms} = :file.consult(path)

    Map.new(terms, fn {key, value} -> {to_string(key), value} end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(value) when is_list(value), do: value == []
  defp blank?(_value), do: false
end

AgentDb.VerifyPackage.run()
