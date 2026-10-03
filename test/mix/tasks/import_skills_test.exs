defmodule Mix.Tasks.AgentDb.ImportSkillsTest do
  @moduledoc """
  The command line import, driven the way an operator would drive it.

  The task is the same import the console performs, so what is asserted here is
  the command: the arguments it accepts, what it prints for each skill, and the
  status it leaves behind when something did not work.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentDb.Cache
  alias Mix.Tasks.AgentDb.ImportSkills

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  describe "a folder" do
    test "imports the one skill it holds and reports it" do
      folder = skill_folder("alpha", "the manifest")

      output = run([folder, "--user", "alice"])

      assert output =~ "imported"
      assert output =~ "alpha"
      assert output =~ "1 file"
      assert {:ok, "the manifest"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end

    test "imports a collection, one line per skill" do
      folder = tmp("collection")
      write(folder, "alpha/SKILL.md", "alpha's manifest\n")
      write(folder, "alpha/references/guide.md", "alpha's guide\n")
      write(folder, "beta/SKILL.md", "beta's manifest\n")

      output = run([folder, "--user", "alice"])

      assert output =~ "imported alpha"
      assert output =~ "imported beta"
      assert output =~ "2 files"

      assert {:ok, "alpha's guide\n"} =
               AgentDb.read("viking://user/alice/skills/alpha/references/guide.md")
    end
  end

  describe "an archive" do
    test "imports the skills it holds" do
      archive =
        archive([{"skills/alpha/SKILL.md", "alpha\n"}, {"skills/beta/SKILL.md", "beta\n"}])

      output = run([archive, "--user", "alice"])

      assert output =~ "imported alpha"
      assert output =~ "imported beta"
      assert {:ok, "alpha\n"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end

    test "a gzip-compressed archive is read the same way" do
      archive = archive([{"alpha/SKILL.md", "alpha\n"}])
      gz = Path.join(tmp("archives"), "skills.tar.gz")
      File.write!(gz, :zlib.gzip(File.read!(archive)))

      assert run([gz, "--user", "alice"]) =~ "imported alpha"
      assert {:ok, "alpha\n"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end
  end

  describe "a skill already stored" do
    test "is reported as replaced, and its old files go" do
      folder = skill_folder("alpha", "the manifest", "old.md", "the old file")
      assert run([folder, "--user", "alice"]) =~ "imported"

      output = run([skill_folder("alpha", "a newer manifest"), "--user", "alice"])

      assert output =~ "replaced"
      refute output =~ "imported"
      assert {:ok, "a newer manifest"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:error, :not_found} = AgentDb.read("viking://user/alice/skills/alpha/old.md")
    end
  end

  describe "what the command refuses" do
    test "a source the importer refuses fails the command, with the reason" do
      archive = traversal_archive()

      assert_raise Mix.Error, ~r/Refused: .*escaped\.md/, fn ->
        run([archive, "--user", "alice"])
      end

      assert {:error, :not_found} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end

    test "a user id that is not one URI segment fails the command" do
      folder = skill_folder("alpha", "the manifest")

      assert_raise Mix.Error, ~r/cannot be a user id/, fn ->
        run([folder, "--user", "alice/../root"])
      end
    end

    test "a missing --user fails the command" do
      folder = skill_folder("alpha", "the manifest")

      assert_raise Mix.Error, ~r/--user/, fn -> run([folder]) end
    end

    test "a missing path argument fails the command" do
      assert_raise Mix.Error, ~r/Expected one PATH/, fn -> run(["--user", "alice"]) end
    end

    test "one skill the store cannot take fails the command" do
      folder = skill_folder("alpha", "the manifest")

      # A store whose writes are broken fails every skill of the import, and the
      # command has to say so rather than report a success it cannot deliver.
      assert :ok =
               AgentDb.Store.Writer.call(fn conn ->
                 AgentDb.Store.SQLite.exec(conn, "DROP TABLE job_queue")
               end)

      try do
        assert_raise Mix.Error, ~r/One or more skills/, fn -> run([folder, "--user", "alice"]) end
      after
        :ok = AgentDb.Store.Writer.call(fn conn -> AgentDb.Store.SQLite.ensure_schema(conn) end)
      end

      assert {:error, :not_found} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
    end
  end

  describe "the help it prints" do
    test "agrees with the documented limits" do
      # The README and the task's own help both restate the limits, so neither is
      # allowed to drift from the ones the importer actually applies.
      readme = File.read!("README.md")
      limits = AgentDb.skill_import_limits()

      assert readme =~ "mix agent_db.import_skills ./my-skills --user alice"
      assert readme =~ "mix agent_db.import_skills ./skills.tar.gz --user alice"
      assert readme =~ "| Files and entries in one source | #{limits.max_entries} |"

      assert readme =~
               "| Bytes, compressed input and once expanded | #{thousands(limits.max_bytes)} |"
    end

    test "names the layouts, the limits and the replacement rule" do
      limits = AgentDb.skill_import_limits()
      {:docs_v1, _, _, _, %{"en" => help}, _, _} = Code.fetch_docs(ImportSkills)

      assert help =~ "mix agent_db.import_skills PATH --user USER_ID"
      assert help =~ "gzip-compressed"
      assert help =~ "SKILL.md"
      assert help =~ "replaced whole"
      assert help =~ to_string(limits.max_entries)
      assert help =~ to_string(limits.max_bytes)
    end
  end

  # -- helpers --

  # Runs the task and returns what it printed. The colour is dropped rather than
  # asserted on: what an operator reads is the wording, and the wording is what
  # the docs have to match.
  defp run(argv) do
    capture_io(fn -> apply(ImportSkills, :run, [argv]) end)
    |> String.replace(~r/\e\[[0-9;]*m/, "")
  end

  # A member whose path leaves the archive root. A folder cannot hold one -- the
  # walk only ever produces paths inside the folder -- so it is written from
  # inside a folder whose parent holds the file it names.
  # How a limit is written in prose: a separator every three digits, which is
  # what the documentation shows and what a reader compares by eye.
  defp thousands(bytes) do
    bytes
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp traversal_archive do
    outer = tmp("outer")
    write(outer, "escaped.md", "nope\n")
    write(outer, "inner/alpha/SKILL.md", "the manifest\n")
    path = Path.join(tmp("archives"), "traversal.tar")

    :ok =
      File.cd!(Path.join(outer, "inner"), fn ->
        :erl_tar.create(String.to_charlist(path), [~c"../escaped.md", ~c"alpha/SKILL.md"], [])
      end)

    path
  end

  defp skill_folder(name, manifest, extra \\ nil, content \\ nil) do
    folder = tmp(name)
    write(folder, "SKILL.md", manifest)
    if extra, do: write(folder, extra, content)
    folder
  end

  defp archive(members) do
    staging = tmp("staging")

    for {name, content} <- members do
      write(staging, name, content)
    end

    path = Path.join(tmp("archives"), "skills.tar")

    :ok =
      File.cd!(staging, fn ->
        :erl_tar.create(
          String.to_charlist(path),
          Enum.map(members, fn {name, _content} -> String.to_charlist(name) end)
        )
      end)

    path
  end

  # A folder whose own name is `name`, because a folder holding one skill is
  # named after itself.
  defp tmp(name) do
    path =
      Path.join(
        AgentDb.Test.Scratch.dir("agent_db_task"),
        name
      )

    File.mkdir_p!(path)
    path
  end

  defp write(folder, relative, content) do
    path = Path.join(folder, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
