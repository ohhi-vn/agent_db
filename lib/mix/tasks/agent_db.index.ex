defmodule Mix.Tasks.AgentDb.Index do
  @shortdoc "Indexes Elixir sources into the context tree"

  @moduledoc """
  Indexes Elixir sources structurally.

      mix agent_db.index --project NAME --dir PATH

  Options:

    * `--project` - project name used under `viking://resources/NAME/code` (required).
    * `--dir` - directory holding `.ex`/`.exs` files (default `lib`).
    * `--json` - print the outcome as JSON instead of human text.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [project: :string, dir: :string, json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    project = opts[:project] || Mix.raise("Expected --project NAME.")
    dir = opts[:dir] || "lib"

    case AgentDb.CodeIndex.index_dir(project, dir) do
      {:ok, %{indexed: indexed, failed: []}} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(%{project: project, indexed: indexed}))
        else
          Mix.shell().info("indexed #{length(indexed)} files for #{project}")
        end

      {:ok, %{indexed: indexed, failed: failed}} ->
        if opts[:json] do
          Mix.shell().info(
            Jason.encode!(%{
              project: project,
              indexed: indexed,
              failed:
                Enum.map(failed, fn {rel, reason} ->
                  %{file: rel, reason: AgentDb.Observability.error_message(reason)}
                end)
            })
          )
        else
          Mix.shell().info("indexed #{length(indexed)} files for #{project}")

          for {rel, reason} <- failed,
              do:
                Mix.shell().error("failed #{rel}: #{AgentDb.Observability.error_message(reason)}")
        end

        Mix.raise("One or more files could not be indexed.")
    end
  end
end
