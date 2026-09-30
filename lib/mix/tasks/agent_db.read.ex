defmodule Mix.Tasks.AgentDb.Read do
  @shortdoc "Reads a document's full content"

  @moduledoc """
  Reads a document's full content (L2).

      mix agent_db.read URI [--json]

  Options:

    * `--json` - print the result as JSON instead of raw content.
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
        _ -> Mix.raise("Expected one URI to read.")
      end

    case AgentDb.read(uri) do
      {:ok, content} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(%{uri: uri, content: content}))
        else
          Mix.shell().info(content)
        end

      {:error, reason} ->
        Mix.raise("Read failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end
end
