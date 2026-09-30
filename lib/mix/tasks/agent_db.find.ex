defmodule Mix.Tasks.AgentDb.Find do
  @shortdoc "Discovers paths by literal substring"

  @moduledoc """
  Discovers files and directories whose URI path contains `TERM`.

      mix agent_db.find TERM [--scope URI] [--limit N] [--json]

  Options:

    * `--scope` - a `viking://` URI to limit the search.
    * `--limit` - maximum results (default `50`).
    * `--json` - print results as JSON instead of one URI per line.
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
        _ -> Mix.raise("Expected one TERM to find.")
      end

    find_opts =
      []
      |> put_opt(:scope, opts[:scope])
      |> put_opt(:limit, opts[:limit] || 50)

    case AgentDb.find(term, find_opts) do
      {:ok, results} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(results))
        else
          for r <- results, do: Mix.shell().info(r[:uri] || r["uri"] || inspect(r))
        end

      {:error, reason} ->
        Mix.raise("Find failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
