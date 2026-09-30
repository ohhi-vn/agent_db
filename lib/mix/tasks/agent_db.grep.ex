defmodule Mix.Tasks.AgentDb.Grep do
  @shortdoc "Searches document content by literal substring"

  @moduledoc """
  Searches full document content (L2) for a literal substring.

      mix agent_db.grep TERM [--scope URI] [--limit N] [--json]

  Options:

    * `--scope` - a `viking://` URI to limit the search.
    * `--limit` - maximum results (default `50`).
    * `--json` - print results as JSON instead of one match per line.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [scope: :string, limit: :integer, json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    term =
      case args do
        [t] -> t
        _ -> Mix.raise("Expected one TERM to grep for.")
      end

    grep_opts =
      []
      |> put_opt(:scope, opts[:scope])
      |> put_opt(:limit, opts[:limit] || 50)

    case AgentDb.grep(term, grep_opts) do
      {:ok, results} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(results))
        else
          for r <- results do
            Mix.shell().info("#{r[:uri] || r["uri"]}:#{r[:line_number] || r["line_number"]}")
          end
        end

      {:error, reason} ->
        Mix.raise("Grep failed: #{inspect(reason)}")
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
