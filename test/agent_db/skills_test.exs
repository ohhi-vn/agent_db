defmodule AgentDb.SkillsTest do
  @moduledoc """
  Importing skills through the facade.

  These are about what an import does to a store: where it puts a skill, what a
  replacement removes, what a refused source leaves alone, and what a cached read
  says afterwards. What a bundle may look like is `AgentDb.Skills.Source`'s own
  business and is asserted there.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Cache
  alias AgentDb.Test.Fakes.Storage, as: FakeStorage
  alias AgentDb.Test.Script

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Script.clear(:fake_storage)
    end)

    :ok
  end

  describe "a new import" do
    test "puts a skill below the selected user's skills, with its files where it had them" do
      assert {:ok, %{skills: [skill]}} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "the manifest")})

      assert skill.name == "alpha"
      assert skill.status == :imported
      assert skill.files == 2

      assert {:ok, "the manifest"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")

      assert {:ok, "the guide"} =
               AgentDb.read("viking://user/alice/skills/alpha/references/guide.md")

      assert {:ok, ["SKILL.md", "references"]} = AgentDb.list("viking://user/alice/skills/alpha")
    end

    test "keeps each user's skills to their own subtree" do
      assert {:ok, _} = AgentDb.import_skills("alice", {:uploads, collection(alpha: "alice's")})
      assert {:ok, _} = AgentDb.import_skills("bob", {:uploads, collection(alpha: "bob's")})

      assert {:ok, "alice's"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:ok, "bob's"} = AgentDb.read("viking://user/bob/skills/alpha/SKILL.md")
    end

    test "each imported file is queued for the work a write queues" do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "the manifest")})

      # A write queues an embedding and both summaries per file; an imported file
      # is a document like any other, so it is queued for the same three.
      for uri <- [
            "viking://user/alice/skills/alpha/SKILL.md",
            "viking://user/alice/skills/alpha/references/guide.md"
          ] do
        assert jobs_for(uri) == 3
      end
    end
  end

  describe "a skill already stored under the same name" do
    test "is replaced whole, and a file the new source omits goes with it" do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "the manifest")})

      assert {:ok, %{skills: [skill]}} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "a newer manifest"}]}
               )

      assert skill.status == :replaced
      assert {:ok, "a newer manifest"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")

      assert {:error, :not_found} =
               AgentDb.read("viking://user/alice/skills/alpha/references/guide.md")
    end

    test "leaves other skills, and other users, as they were" do
      assert {:ok, _} = AgentDb.import_skills("alice", {:uploads, collection(alpha: "alpha one")})
      assert {:ok, _} = AgentDb.import_skills("alice", {:uploads, collection(beta: "beta one")})
      assert {:ok, _} = AgentDb.import_skills("bob", {:uploads, collection(alpha: "bob's")})

      assert {:ok, _} = AgentDb.import_skills("alice", {:uploads, collection(alpha: "alpha two")})

      assert {:ok, "alpha two"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:ok, "beta one"} = AgentDb.read("viking://user/alice/skills/beta/SKILL.md")
      assert {:ok, "bob's"} = AgentDb.read("viking://user/bob/skills/alpha/SKILL.md")
    end

    test "takes the whole subtree with it, queued work and all" do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "the manifest")})

      stale = "viking://user/alice/skills/alpha/references/guide.md"

      assert {:ok, %{skills: [skill]}} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "a newer manifest"}]}
               )

      assert skill.status == :replaced
      # The work queued for a file that is gone must not outlive it, or a worker
      # would spend a model call on a document that no longer exists.
      assert jobs_for(stale) == 0
      assert jobs_for("viking://user/alice/skills/alpha/SKILL.md") == 3
    end
  end

  describe "a source that is refused" do
    test "leaves the store exactly as it was" do
      assert {:ok, _} = AgentDb.import_skills("alice", {:uploads, collection(alpha: "alpha one")})

      assert {:error, {:unsafe_path, "../escape.md", :traversal}} =
               AgentDb.import_skills("alice", {
                 :uploads,
                 collection(alpha: "a newer manifest") ++
                   [%{path: "../escape.md", content: "nope"}]
               })

      assert {:ok, "alpha one"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:error, :not_found} = AgentDb.read("viking://resources/escape.md")
      assert {:ok, ["SKILL.md", "references"]} = AgentDb.list("viking://user/alice/skills/alpha")
    end

    test "reports a reason the operator can act on" do
      assert {:error, reason} = AgentDb.import_skills("alice", {:uploads, []})

      assert AgentDb.skill_import_error_message(reason) =~ "no files"
    end

    test "refuses a user id that could not be a URI segment" do
      assert {:error, {:invalid_user_id, "alice/../root"}} =
               AgentDb.import_skills("alice/../root", {:uploads, collection(alpha: "x")})

      assert AgentDb.skill_import_error_message({:invalid_user_id, "a/b"}) =~ "one URI segment"
    end
  end

  describe "after a replacement" do
    test "a read of what the new source removed is not answered from the cache" do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "the manifest")})

      removed = "viking://user/alice/skills/alpha/references/guide.md"

      # Warm both caches with what is about to stop being true.
      assert {:ok, "the guide"} = AgentDb.read(removed)
      assert {:ok, ["SKILL.md", "references"]} = AgentDb.list("viking://user/alice/skills/alpha")

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "a newer manifest"}]}
               )

      assert {:error, :not_found} = AgentDb.read(removed)
      assert {:ok, ["SKILL.md"]} = AgentDb.list("viking://user/alice/skills/alpha")
    end

    test "a read of what the new source wrote is not answered from before it" do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "the manifest")})

      written = "viking://user/alice/skills/alpha/SKILL.md"

      assert {:ok, "the manifest"} = AgentDb.read(written)

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "a newer manifest"}]}
               )

      assert {:ok, "a newer manifest"} = AgentDb.read(written)
      # ...and a cold read agrees with the warm one.
      Cache.clear()
      assert {:ok, "a newer manifest"} = AgentDb.read(written)
    end
  end

  describe "when the store cannot take one skill of several" do
    setup do
      Application.put_env(:agent_db, :storage_adapter, AgentDb.Test.Fakes.Storage)
      :ok = restart_app()
      FakeStorage.reset()

      on_exit(fn ->
        Application.delete_env(:agent_db, :storage_adapter)
        FakeStorage.reset()
        Script.clear(:fake_storage)
      end)

      :ok
    end

    test "the other skills still land, and the failed one is reported as failed" do
      # A provider that takes every skill but one: the store refusing one
      # replacement must not take the rest of the source with it.
      FakeStorage.stub(:replace_skill, fn uri, files ->
        if String.contains?(uri, "beta") do
          {:error, :no_space}
        else
          FakeStorage.do_replace_skill(uri, files)
        end
      end)

      uploads = [
        %{path: "alpha/SKILL.md", content: "alpha\n"},
        %{path: "beta/SKILL.md", content: "beta\n"},
        %{path: "gamma/SKILL.md", content: "gamma\n"}
      ]

      assert {:ok, %{skills: skills}} = AgentDb.import_skills("alice", {:uploads, uploads})

      assert Enum.map(skills, & &1.name) == ["alpha", "beta", "gamma"]

      assert %{name: "alpha", status: :imported} = Enum.at(skills, 0)
      assert %{name: "beta", status: :failed, reason: :no_space} = Enum.at(skills, 1)
      assert %{name: "gamma", status: :imported} = Enum.at(skills, 2)

      assert {:ok, "alpha\n"} = AgentDb.read("viking://user/alice/skills/alpha/SKILL.md")
      assert {:error, :not_found} = AgentDb.read("viking://user/alice/skills/beta/SKILL.md")
      assert {:ok, "gamma\n"} = AgentDb.read("viking://user/alice/skills/gamma/SKILL.md")
    end
  end

  # Vector-search behaviour is only observable when the sqlite-vec extension
  # loaded and vec_nodes exists. Where it is unavailable this scenario is inert,
  # as it is elsewhere in the suite.
  test "a file written by a replacement is not searchable on the old one's embedding" do
    if match?({:ok, true}, table_exists?("vec_nodes")) do
      assert {:ok, _} =
               AgentDb.import_skills("alice", {:uploads, collection(alpha: "searchable")})

      assert {:ok, [_ | _]} = AgentDb.search("searchable", scope: "viking://user/alice/skills")

      assert {:ok, _} =
               AgentDb.import_skills(
                 "alice",
                 {:uploads, [%{path: "alpha/SKILL.md", content: "entirely unrelated"}]}
               )

      assert {:ok, results} = AgentDb.search("searchable", scope: "viking://user/alice/skills")
      assert results == []
    end
  end

  # -- helpers --

  # A browser's files for one skill in a collection, as a directory selection
  # would send them.
  defp collection(skills) do
    for {name, manifest} <- skills do
      [
        %{path: "my-skills/#{name}/SKILL.md", content: manifest},
        %{path: "my-skills/#{name}/references/guide.md", content: "the guide"}
      ]
    end
    |> List.flatten()
  end

  defp jobs_for(uri) do
    AgentDb.Store.Writer.call(fn conn ->
      case AgentDb.Store.SQLite.query_one(
             conn,
             "SELECT COUNT(*) FROM job_queue WHERE json_extract(payload, '$.uri') = ?1 AND status IN ('pending','running')",
             [uri]
           ) do
        {:ok, [count]} -> count
        _other -> 0
      end
    end)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  defp table_exists?(table) do
    AgentDb.Store.Writer.call(fn conn ->
      case AgentDb.Store.SQLite.query_one(
             conn,
             "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
             [table]
           ) do
        {:ok, nil} -> {:ok, false}
        {:ok, _} -> {:ok, true}
      end
    end)
  end
end
