defmodule Mix.Tasks.AgentDb.Overview do
  @shortdoc "Reads a document's L1 overview"

  @moduledoc """
  Reads a document's L1 overview -- the bounded scan of its key points, for
  deciding whether to read the content at all.

      mix agent_db.overview URI [--json]

  Options:

    * `--json` - print the result as JSON instead of the overview alone.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    uri =
      case args do
        [u] -> u
        _ -> Mix.raise("Expected one URI to read the overview of.")
      end

    case AgentDb.overview(uri) do
      {:ok, overview} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(%{uri: uri, overview: overview}))
        else
          Mix.shell().info(overview)
        end

      {:error, reason} ->
        Mix.raise("Overview failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end
end
