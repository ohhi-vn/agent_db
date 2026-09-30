defmodule Mix.Tasks.AgentDb.Search do
  @shortdoc "Searches the context tree"

  @moduledoc """
  Searches the context tree.

      mix agent_db.search TERM [--mode keyword|vector|hybrid] [--scope URI] [--top-k N] [--json]

  Options:

    * `--mode` - search mode (default `keyword`).
    * `--scope` - a `viking://` URI to limit the search.
    * `--top-k` - maximum results (default `10`).
    * `--json` - print results as JSON instead of one URI per line.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [mode: :string, scope: :string, top_k: :integer, json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    term =
      case args do
        [t] -> t
        _ -> Mix.raise("Expected one TERM to search for.")
      end

    search_opts = [
      mode: mode_opt(opts[:mode]),
      scope: opts[:scope],
      top_k: opts[:top_k] || 10
    ]

    case AgentDb.search(term, search_opts) do
      {:ok, results} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(results))
        else
          for r <- results, do: Mix.shell().info(r[:uri] || r["uri"] || inspect(r))
        end

      {:error, reason} ->
        Mix.raise("Search failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end

  defp mode_opt(nil), do: :keyword
  defp mode_opt("keyword"), do: :keyword
  defp mode_opt("vector"), do: :vector
  defp mode_opt("hybrid"), do: :hybrid
  defp mode_opt(other), do: Mix.raise("Unknown mode #{inspect(other)}.")
end
