defmodule Mix.Tasks.AgentDb.ImportSkills do
  @shortdoc "Imports Agent Skills from a folder or a tar archive"

  @moduledoc """
  Imports Agent Skills from the command line.

      mix agent_db.import_skills PATH --user USER_ID

  `PATH` is a folder or a tar archive, gzip-compressed or not. A folder holding a
  `SKILL.md` at its own root is one skill, named after the folder; a folder (or
  archive) of immediate skill folders is a collection of them, and an archive may
  add one wrapper directory above them. Every text file in a skill is stored
  below `viking://user/USER_ID/skills/SKILL_NAME` at the path it had inside the
  skill.

  A skill already stored under that name is replaced whole: files the new source
  does not have are removed with it, and a replacement that fails leaves the
  stored skill as it was. Every skill's outcome is printed, and the task exits
  with a failure if any skill failed or the source was refused.

  Options:

    * `--user` - the user whose skills subtree the skills are imported into
      (required).
    * `--json` - print per-skill outcomes as JSON instead of human text.
    * `--no-compile` - do not compile the project before running.

  ## What it refuses

  An unsafe path, a link, a duplicate path, a path stored both as a file and a
  directory, a skill with no `SKILL.md`, and a file that is not UTF-8 text, plus
  the bounds one import accepts: at most #{AgentDb.skill_import_limits().max_entries} files
  and #{AgentDb.skill_import_limits().max_bytes} bytes once expanded. A source refused for
  any of them leaves the store exactly as it was. macOS metadata (`._` sidecars
  and `.DS_Store` files) is set aside rather than refused.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [user: :string, json: :boolean, no_compile: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start", if(opts[:no_compile], do: ["--no-compile"], else: []))

    with {:ok, path} <- source(args),
         {:ok, user} <- user(opts) do
      import_skills(user, path, opts[:json] || false)
    end
  end

  defp source([path]), do: {:ok, path}
  defp source(_args), do: Mix.raise("Expected one PATH: a skills folder or a tar archive.")

  defp user(opts) do
    case opts[:user] do
      nil -> Mix.raise("Expected --user USER_ID: the user to import the skills for.")
      user -> {:ok, user}
    end
  end

  defp import_skills(user, path, json?) do
    case AgentDb.import_skills(user, {:path, path}) do
      {:ok, %{skills: skills}} ->
        if json? do
          Mix.shell().info(Jason.encode!(Enum.map(skills, &skill_json(&1, user))))
        else
          Enum.each(skills, &report(&1, user))
        end

        if Enum.any?(skills, &(&1.status == :failed)), do: Mix.raise(failed(user))

      {:error, reason} ->
        Mix.raise("Refused: " <> AgentDb.skill_import_error_message(reason))
    end
  end

  defp skill_json(skill, user) do
    base = %{user: user, name: skill.name, status: to_string(skill.status)}

    base
    |> put_json(:files, Map.get(skill, :files))
    |> put_json(
      :reason,
      case Map.get(skill, :reason) do
        nil -> nil
        reason -> AgentDb.skill_import_error_message(reason)
      end
    )
  end

  defp put_json(map, _key, nil), do: map
  defp put_json(map, key, value), do: Map.put(map, key, value)

  defp report(%{status: :failed} = skill, user) do
    Mix.shell().error([
      "failed ",
      style_name(skill.name),
      " for ",
      style_user(user),
      ": " <> AgentDb.skill_import_error_message(skill.reason)
    ])
  end

  defp report(skill, user) do
    Mix.shell().info([
      style_verb(skill.status),
      " ",
      style_name(skill.name),
      " for ",
      style_user(user),
      " (",
      to_string(skill.files),
      if(skill.files == 1, do: " file)", else: " files)")
    ])
  end

  defp style_name(name), do: [IO.ANSI.cyan(), name, IO.ANSI.reset()]
  defp style_user(user), do: [IO.ANSI.magenta(), user, IO.ANSI.reset()]
  defp style_verb(:imported), do: [IO.ANSI.green(), "imported", IO.ANSI.reset()]
  defp style_verb(:replaced), do: [IO.ANSI.yellow(), "replaced", IO.ANSI.reset()]

  defp failed(user) do
    "One or more skills could not be imported for #{user}. " <>
      "Skills that succeeded are stored; run the task again to import the rest."
  end
end
