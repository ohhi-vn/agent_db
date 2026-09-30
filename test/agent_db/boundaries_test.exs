defmodule AgentDb.BoundariesTest do
  @moduledoc """
  Which direction the dependencies point.

  The ports are worth having only if the layers above them are written as
  though the infrastructure beneath might change. A workflow that reaches for
  the database, a model process or a cache table has not been separated from
  them, whatever the modules are called -- so these assertions read the code
  rather than trust the structure.
  """
  use ExUnit.Case, async: false

  @core [
    AgentDb.Application.Documents,
    AgentDb.Application.Memories,
    AgentDb.Application.Search,
    AgentDb.Application.Sessions,
    AgentDb.Application.Skills,
    AgentDb.Application.Status
  ]

  describe "core workflows" do
    test "reach storage and inference through their ports, never by name" do
      # The things a workflow is allowed to name: the runtime that answers which
      # provider is in use, the cache it reads through, the URI grammar its own
      # inputs are written in, the settings that govern it, the stateless
      # instrumentation it emits (no process, no backend, fails safe), and the
      # reader that turns one kind of input into another before the workflow
      # sees it. What it may not name is a provider.
      allowed = [
        AgentDb.Runtime,
        AgentDb.Cache,
        AgentDb.URI,
        AgentDb.Config,
        AgentDb.Observability,
        AgentDb.Skills.Source
      ]

      for module <- @core do
        for reference <- direct_references(module), reference != module do
          assert reference in allowed,
                 "#{inspect(module)} names #{inspect(reference)} directly, so it is coupled to that provider " <>
                   "rather than to the port it should be using"
        end
      end
    end

    test "do not name any infrastructure module" do
      # `AgentDb.Cache` is deliberately absent: it is an internal optimization
      # the application layer owns and is allowed to use. What a workflow must
      # not do is reach the database, the model process or the queue directly.
      infrastructure = [
        AgentDb.Store.SQLite,
        AgentDb.Store.Nodes,
        AgentDb.Store.Memories,
        AgentDb.Store.Reader,
        AgentDb.Store.Writer,
        AgentDb.JobQueue,
        AgentDb.ML.ModelManager
      ]

      for module <- @core do
        source = File.read!(source_of(module))

        for {line, text} <- lines(source) do
          for name <- infrastructure do
            refute text =~ "alias #{inspect(name)}",
                   "#{Path.relative_to_cwd(source_of(module))}:#{line} aliases #{inspect(name)}"
          end
        end
      end
    end

    test "do not read a connection or issue a statement" do
      for module <- @core do
        source = File.read!(source_of(module))

        # SQL is the storage adapter's vocabulary. A statement in a workflow
        # would mean the storage decision leaked upward.
        refute source =~ ~r/"\s*(SELECT|INSERT|UPDATE|DELETE|CREATE)\b/i,
               "#{Path.relative_to_cwd(source_of(module))} contains SQL"
      end
    end

    test "do not name a transport module" do
      for module <- @core do
        for reference <- direct_references(module) do
          refute String.starts_with?(inspect(reference), "AgentDbWeb"),
                 "#{inspect(module)} names #{inspect(reference)}, so the store depends on how it is exposed"
        end
      end
    end
  end

  describe "the web layer" do
    test "reaches the store through the facade, not the machinery beneath it" do
      # A request handler needs presentation, not the database or the model
      # process. Reading either from here would make the HTTP surface a second
      # way into the store, and a change to either a change to the wire.
      for module <- web_modules() do
        source = File.read!(source_of(module))

        for name <- [
              AgentDb.Store.SQLite,
              AgentDb.Store.Reader,
              AgentDb.Store.Writer,
              AgentDb.Store.Nodes,
              AgentDb.ML.ModelManager,
              AgentDb.JobQueue
            ] do
          refute source =~ "alias #{inspect(name)}",
                 "#{Path.relative_to_cwd(source_of(module))} aliases #{inspect(name)}"
        end
      end
    end

    test "gets its state from the facade" do
      # The console and the channel report what the facade reports, so what an
      # operator sees is what a program gets.
      for module <- [AgentDbWeb.Context, AgentDbWeb.Channel] do
        source = File.read!(source_of(module))
        assert source =~ "AgentDb", "#{inspect(module)} does not reach the store at all"
      end
    end
  end

  describe "the adapters" do
    test "are the only place the infrastructure is named" do
      for module <- [
            AgentDb.Adapters.SQLite,
            AgentDb.Adapters.Inference,
            AgentDb.Adapters.Phoenix
          ] do
        assert module.module_info(:attributes)[:behaviour] != nil,
               "#{inspect(module)} declares no port, so it is not a provider of one"
      end
    end
  end

  # The modules a core workflow calls that are not its own collaborators. Named
  # modules are what this asserts on; runtime lookups through AgentDb.Runtime
  # are the seam, and a workflow may only use that one.
  defp direct_references(module) do
    source = File.read!(source_of(module))

    ~r/\bAgentDb(?:\.[A-Z][A-Za-z0-9_]*)+/
    |> Regex.scan(source)
    |> Enum.map(fn [reference] -> safe_module(reference) end)
    |> Enum.filter(&(&1 != nil))
    |> Enum.uniq()
  end

  defp safe_module(reference) do
    Module.concat([reference])
  rescue
    ArgumentError -> nil
  end

  defp lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {text, line} -> {line, text} end)
  end

  defp web_modules do
    Path.wildcard("lib/agent_db_web/**/*.ex")
    |> Enum.map(fn path ->
      path |> File.read!() |> extract_modules()
    end)
  end

  defp extract_modules(source) do
    case Regex.run(~r/^defmodule ([A-Za-z0-9_.]+) do/m, source) do
      [_, name] -> Module.concat([name])
      nil -> nil
    end
  end

  # A test asserts on source, so it needs the file the module was compiled from.
  # Elixir records it per function chunk, which is the only reliable way to
  # find a source file for a module that may be defined anywhere.
  defp source_of(module) do
    module.module_info(:compile)[:source]
  end
end
