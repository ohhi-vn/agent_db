defmodule Mix.Tasks.AgentDb.Tree do
  @shortdoc "Shows the context tree"

  @moduledoc """
  Shows a depth-limited projection of the context tree.

      mix agent_db.tree URI [--depth N] [--json]

  Options:

    * `--depth` - projection depth (default `2`).
    * `--json` - print the tree as JSON instead of pretty text.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [depth: :integer, json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    uri =
      case args do
        [u] -> u
        _ -> Mix.raise("Expected one URI.")
      end

    depth = opts[:depth] || 2

    case AgentDb.tree(uri, depth) do
      {:ok, tree} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(tree))
        else
          Mix.shell().info(inspect(tree, pretty: true))
        end

      {:error, reason} ->
        Mix.raise("Tree failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end
end
