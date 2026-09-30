defmodule Mix.Tasks.AgentDb.ImportData do
  @shortdoc "Imports store data from a tar archive exported by another agent"

  @moduledoc """
  Imports store data from a tar archive.

      mix agent_db.import_data PATH [--json]

  `PATH` is a `.tar` or `.tar.gz` file created by `mix agent_db.export_data`
  (recognized by content, not by name). The archive is validated whole before
  anything is written; a refused archive leaves the store exactly as it was.

  Import merges by URI: missing URIs are created, present ones are revised in
  place, sessions with a colliding id and different messages are skipped, and
  nothing outside the archive is deleted.

  Options:

    * `--json` - print the result as JSON instead of human text.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    with {:ok, path} <- source(args) do
      import_data(path, opts)
    end
  end

  defp source([path]), do: {:ok, path}
  defp source(_args), do: Mix.raise("Expected one PATH: the .tar or .tar.gz file to import.")

  defp import_data(path, opts) do
    case AgentDb.import_data(path) do
      {:ok, result} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(result_json(result)))
        else
          Mix.shell().info(
            "imported #{result.documents} documents, #{result.memories} memories, " <>
              "#{result.sessions} sessions (#{result.messages} messages)" <>
              skipped_suffix(result)
          )
        end

      {:error, reason} ->
        Mix.raise("Import failed: " <> AgentDb.export_data_error_message(reason))
    end
  end

  defp skipped_suffix(%{skipped_sessions: []}), do: ""
  defp skipped_suffix(%{skipped_sessions: skipped}), do: ", skipped #{length(skipped)} sessions"

  defp result_json(result) do
    %{
      documents: result.documents,
      memories: result.memories,
      sessions: result.sessions,
      messages: result.messages,
      skipped_sessions: result.skipped_sessions
    }
  end
end
