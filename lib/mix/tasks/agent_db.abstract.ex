defmodule Mix.Tasks.AgentDb.Abstract do
  @shortdoc "Reads a document's L0 abstract"

  @moduledoc """
  Reads a document's L0 abstract -- the one-line answer to what this document is
  about, for deciding whether to read the content at all.

      mix agent_db.abstract URI [--json]

  Options:

    * `--json` - print the result as JSON instead of the abstract alone.
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
        _ -> Mix.raise("Expected one URI to read the abstract of.")
      end

    case AgentDb.abstract(uri) do
      {:ok, abstract} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(%{uri: uri, abstract: abstract}))
        else
          Mix.shell().info(abstract)
        end

      {:error, reason} ->
        Mix.raise("Abstract failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end
end
