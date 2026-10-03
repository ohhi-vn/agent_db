defmodule Mix.Tasks.AgentDb.ExportData do
  @shortdoc "Exports store data to a tar archive for another agent to import"

  @moduledoc """
  Exports store data to a tar archive.

      mix agent_db.export_data PATH [--scope URI] [--json]

  `PATH` is the destination `.tar` or `.tar.gz` file. Documents (full content
  plus caller-supplied abstract/overview), memory provenance, and sessions are
  written into one archive with a manifest. Another store restores it with
  `mix agent_db.import_data`.

  With `--scope` only documents and memories beneath that `viking://` URI are
  exported; sessions are included only for a full export. A scope that does
  not exist fails the command and writes no file. An export is a best-effort
  point-in-time snapshot; a second export/import closes the gap left by
  concurrent writes.

  Options:

    * `--scope` - a `viking://` URI limiting the export to one subtree.
    * `--json` - print the result as JSON instead of human text.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [scope: :string, json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    with {:ok, path} <- destination(args) do
      export_data(path, opts)
    end
  end

  defp destination([path]), do: {:ok, path}

  defp destination(_args),
    do: Mix.raise("Expected one PATH: the destination .tar or .tar.gz file.")

  defp export_data(path, opts) do
    export_opts = if opts[:scope], do: [scope: opts[:scope]], else: []

    case AgentDb.export_data(path, export_opts) do
      {:ok, result} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(result_json(result)))
        else
          Mix.shell().info(
            "exported #{result.documents} documents, #{result.memories} memories, " <>
              "#{result.sessions} sessions (#{result.messages} messages) to #{result.path}"
          )
        end

      {:error, reason} ->
        Mix.raise("Export failed: " <> AgentDb.export_data_error_message(reason))
    end
  end

  defp result_json(result) do
    %{
      path: result.path,
      scope: result.scope,
      documents: result.documents,
      memories: result.memories,
      sessions: result.sessions,
      messages: result.messages
    }
  end
end
