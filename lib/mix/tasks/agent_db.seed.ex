defmodule Mix.Tasks.AgentDb.Seed do
  @shortdoc "Seeds a deterministic demo dataset for dev and test"

  @moduledoc """
  Seeds a deterministic demo dataset for dev and test environments.

      mix agent_db.seed [--prefix URI] [--force] [--clean] [--allow-prod] [--json]

  Builds the same baseline on every run: documents under the demo prefix
  (default `viking://resources/demo`), one typed memory per taxonomy type,
  one session committed into the tree, one demo skill, and two indexed Elixir
  sources for the demo project. Re-running converges without duplication.

  A non-empty store is refused unless `--force` (merge: missing seed URIs
  are created, present ones revised in place, nothing deleted) or `--clean`
  (only the seed scope is removed first: the prefix subtree, the `demo-*`
  memories, the demo skill, and the demo code prefix; data outside that scope
  survives) is given. A refusal writes nothing. `--force` and `--clean`
  cannot be combined.

  In production (`Mix.env() == :prod`) seeding is refused unless
  `--allow-prod` is passed. Rollback is `mix agent_db.read` to inspect,
  then removing the prefix subtree and forgetting the `demo-*` memory URIs;
  re-seeding afterwards converges.

  Reads need no model: keyword search, find, and grep reach seeded content
  immediately, while embeddings and summaries regenerate through the existing
  job queue.

  Options:

    * `--prefix` - demo prefix for documents and the committed session
      (default `viking://resources/demo`).
    * `--force` - merge into a non-empty store instead of refusing it.
    * `--clean` - remove only the seed scope, then seed.
    * `--allow-prod` - allow seeding when `Mix.env() == :prod`.
    * `--json` - print the result as JSON instead of human text.
    * `--no-compile` - do not compile the project before running.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [
    prefix: :string,
    force: :boolean,
    clean: :boolean,
    allow_prod: :boolean,
    json: :boolean,
    no_compile: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    if opts[:force] && opts[:clean] do
      Mix.raise("Seed failed: --force and --clean cannot be combined.")
    end

    seed_opts =
      [
        prefix: opts[:prefix],
        force: opts[:force] || false,
        clean: opts[:clean] || false,
        allow_prod: opts[:allow_prod] || false,
        env: Mix.env()
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case AgentDb.Seed.seed(seed_opts) do
      {:ok, report} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(result_json(report)))
        else
          Mix.shell().info(
            "seeded #{report.documents} documents, #{report.memories} memories, " <>
              "#{report.sessions} session (#{report.messages} messages), " <>
              "#{report.skills} skill (#{report.skill_files} files), " <>
              "#{report.indexed} code files under #{report.prefix}"
          )
        end

      {:error, reason} ->
        Mix.raise("Seed failed: " <> AgentDb.Observability.error_message(reason))
    end
  end

  defp result_json(report) do
    %{
      prefix: report.prefix,
      documents: report.documents,
      memories: report.memories,
      sessions: report.sessions,
      messages: report.messages,
      session: report.session,
      skills: report.skills,
      skill_files: report.skill_files,
      indexed: report.indexed
    }
  end
end
