defmodule Mix.Tasks.AgentDb.Recall do
  @shortdoc "Reads memories back"

  @moduledoc """
  Reads memories back, optionally scoped.

      mix agent_db.recall [URI] [--type TYPE] [--term TERM] [--include-superseded] [--json]

  With no arguments every active memory is recalled. A positional URI recalls
  one memory or subtree; `--type` recalls a whole type (e.g. `preferences`).

  Options:

    * `--type` - memory type to recall.
    * `--term` - restrict to memories whose value contains this substring.
    * `--include-superseded` - also return superseded assertions.
    * `--json` - print results as JSON instead of one value per line.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [
    type: :string,
    term: :string,
    include_superseded: :boolean,
    json: :boolean,
    no_compile: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    recall_opts =
      []
      |> put_positional_uri(args)
      |> put_opt(:type, opts[:type])
      |> put_opt(:term, opts[:term])
      |> put_opt(:include_superseded, opts[:include_superseded] || false)

    case AgentDb.recall(recall_opts) do
      {:ok, memories} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(memories))
        else
          for m <- memories, do: Mix.shell().info(m[:value] || m["value"] || inspect(m))
        end

      {:error, reason} ->
        Mix.raise("Recall failed: #{AgentDb.Observability.error_message(reason)}")
    end
  end

  defp put_positional_uri(opts, [uri]), do: Keyword.put(opts, :uri, uri)
  defp put_positional_uri(opts, []), do: opts
  defp put_positional_uri(_opts, _args), do: Mix.raise("Expected at most one URI.")

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
