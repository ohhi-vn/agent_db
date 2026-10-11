defmodule AgentDb.SeedTest do
  @moduledoc """
  The deterministic demo dataset, driven through the public seed API.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Cache
  alias AgentDb.Seed

  @prefix "viking://resources/demo"

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  describe "first seed" do
    test "populates documents, memories, session, skill, and code with a per-kind report" do
      assert {:ok, report} = Seed.seed()

      assert report.prefix == @prefix
      assert report.documents == 5
      assert report.memories == 5
      assert report.sessions == 1
      assert report.messages == 3
      assert report.session == @prefix <> "/sessions/intro.md"
      assert report.skills == 1
      assert report.skill_files == 2
      assert report.indexed == 2

      assert {:ok, readme} = AgentDb.read(@prefix <> "/readme.md")
      assert readme =~ "seedling-demo"

      assert {:ok, [memory]} = AgentDb.recall("viking://user/memories/events/demo-release")
      assert memory.value =~ "seedling-memory events"

      assert {:ok, committed} = AgentDb.read(@prefix <> "/sessions/intro.md")
      assert committed =~ "seedling-session"

      assert {:ok, manifest} = AgentDb.read("viking://user/demo/skills/demo-skill/SKILL.md")
      assert manifest =~ "seedling-skill"
    end

    test "keyword paths reach seeded content with no model" do
      assert {:ok, _} = Seed.seed()

      assert {:ok, [_ | _]} = AgentDb.search("seedling-auth", mode: :keyword)
      assert {:ok, [_ | _]} = AgentDb.find("auth-notes", scope: @prefix)
      assert {:ok, [_ | _]} = AgentDb.grep("demo-runbook", scope: @prefix)
      assert {:ok, [_ | _]} = AgentDb.recall(term: "seedling-memory")
    end

    test "code entries are discoverable" do
      assert {:ok, _} = Seed.seed()

      assert {:ok, [_ | _]} = AgentDb.find("demo_seed", scope: "viking://resources/demo/code")
      assert {:ok, [_ | _]} = AgentDb.grep("seedling_code", scope: "viking://resources/demo/code")
    end
  end

  describe "re-seeding" do
    test "converges without duplication" do
      assert {:ok, _} = Seed.seed()
      assert {:ok, report} = Seed.seed(force: true)

      assert report.documents == 5
      assert {:ok, readme} = AgentDb.read(@prefix <> "/readme.md")
      assert readme =~ "seedling-demo"

      assert {:ok, [only]} = AgentDb.recall("viking://user/memories/events/demo-release")
      assert only.status == :active

      assert {:ok, hits} = AgentDb.find("demo-skill", scope: "viking://user/demo/skills")

      assert Enum.any?(hits, &(&1.name == "demo-skill" and &1.kind == :dir))
    end

    test "replaces a same-named skill whole" do
      assert {:ok, _} = Seed.seed()
      :ok = AgentDb.write("viking://user/demo/skills/demo-skill/old.md", "stale")

      assert {:ok, _} = Seed.seed(force: true)

      assert {:error, :not_found} = AgentDb.read("viking://user/demo/skills/demo-skill/old.md")
      assert {:ok, _} = AgentDb.read("viking://user/demo/skills/demo-skill/SKILL.md")
    end
  end

  describe "guards" do
    test "a non-empty store is refused and nothing is written" do
      :ok = AgentDb.write("viking://resources/real.md", "real data")

      assert {:error, :store_not_empty} = Seed.seed()
      assert {:error, :not_found} = AgentDb.read(@prefix <> "/readme.md")
      assert {:ok, []} = AgentDb.recall()
    end

    test "force merges while outside data survives" do
      :ok = AgentDb.write("viking://resources/real.md", "real data")

      assert {:ok, _} = Seed.seed(force: true)

      assert {:ok, "real data"} = AgentDb.read("viking://resources/real.md")
      assert {:ok, _} = AgentDb.read(@prefix <> "/readme.md")
    end

    test "clean removes only the seed scope" do
      assert {:ok, _} = Seed.seed()
      :ok = AgentDb.write("viking://resources/real.md", "real data")
      :ok = AgentDb.write(@prefix <> "/extra.md", "stale extra")

      assert {:ok, _} = Seed.seed(clean: true)

      assert {:ok, "real data"} = AgentDb.read("viking://resources/real.md")
      assert {:error, :not_found} = AgentDb.read(@prefix <> "/extra.md")
      assert {:ok, _} = AgentDb.read(@prefix <> "/readme.md")
    end

    test "production needs an explicit opt-in" do
      assert {:error, :production_guarded} = Seed.seed(env: :prod)
      assert {:error, :not_found} = AgentDb.read(@prefix <> "/readme.md")

      assert {:ok, _} = Seed.seed(env: :prod, allow_prod: true)
      assert {:ok, _} = AgentDb.read(@prefix <> "/readme.md")
    end

    test "an invalid prefix fails without writing" do
      assert {:error, :invalid_uri} = Seed.seed(prefix: "not a uri")
      assert {:ok, []} = AgentDb.recall()
    end
  end

  describe "prefix override" do
    test "isolates documents and the committed session" do
      custom = "viking://resources/custom"

      assert {:ok, report} = Seed.seed(prefix: custom)
      assert report.prefix == custom
      assert report.session == custom <> "/sessions/intro.md"

      assert {:ok, _} = AgentDb.read(custom <> "/readme.md")
      assert {:ok, _} = AgentDb.read(custom <> "/sessions/intro.md")
      assert {:error, :not_found} = AgentDb.read(@prefix <> "/readme.md")
    end
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
