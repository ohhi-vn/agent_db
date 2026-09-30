defmodule Mix.Tasks.AgentDb.Doctor do
  @shortdoc "Checks store health and configuration"

  @moduledoc """
  Checks store health and configuration.

      mix agent_db.doctor [--json]

  Reports database reachability, model status, queue depth, PubSub health,
  and the active inference provider. Exits with failure when the database
  itself is unreachable.

  Options:

    * `--json` - print the report as JSON instead of human text.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    health = AgentDb.health_check()
    models = AgentDb.model_status()
    queue = AgentDb.queue_stats()
    provider = Map.get(models, :provider, :local)
    pubsub = pubsub_ok?()

    if opts[:json] do
      Mix.shell().info(
        Jason.encode!(%{
          db: health.checks.db,
          status: health.status,
          provider: to_string(provider),
          queue: queue,
          pubsub: pubsub
        })
      )
    else
      Mix.shell().info("db: #{inspect(health.checks.db)}")
      Mix.shell().info("models: #{inspect(health.status)}")
      Mix.shell().info("provider: #{inspect(provider)}")
      Mix.shell().info("queue: #{inspect(queue)}")
      Mix.shell().info("pubsub: #{inspect(pubsub)}")
    end

    unless health.checks.db, do: Mix.raise("Database unreachable.")
  end

  defp pubsub_ok? do
    try do
      :ok = Phoenix.PubSub.subscribe(AgentDb.PubSub, "agent_db:doctor")
      :ok = Phoenix.PubSub.unsubscribe(AgentDb.PubSub, "agent_db:doctor")
      true
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end
end
