defmodule AgentDb.LayersTest do
  @moduledoc """
  Reading a document's three layers in one call, each with where it came from.

  The layers exist so a caller can decide what to read before paying to read
  it. These are the assertions that hold that decision to something: the three
  layers arrive together, a derived layer says it was derived, and a caller is
  told one round trip's worth rather than four.
  """
  use ExUnit.Case, async: false

  setup context do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    AgentDb.StorageContract.Helpers.restart_app()
    AgentDb.StorageContract.Helpers.stop_workers()
    AgentDb.Cache.clear()
    prefix = "viking://resources/layers/#{context.line}"

    on_exit(fn ->
      AgentDb.rm(prefix)
      Application.delete_env(:agent_db, :data_dir)
      AgentDb.StorageContract.Helpers.restart_app()
    end)

    {:ok, prefix: prefix}
  end

  describe "layers/1" do
    test "reads all three layers with their text and size", %{prefix: prefix} do
      uri = "#{prefix}/one.md"
      :ok = AgentDb.write(uri, "a body long enough to measure")

      assert %{
               abstract: %{text: text, source: source, chars: chars},
               overview: overview_layer,
               content: content_layer
             } = AgentDb.layers(uri)

      # Nothing was stored for the summaries, so both were derived from L2.
      assert source == :fallback
      assert is_binary(text)
      assert chars == String.length(text)

      assert overview_layer.source == :fallback
      assert content_layer.source == :stored
      assert content_layer.text == "a body long enough to measure"
      assert content_layer.chars == 29
    end

    test "a caller-supplied layer reports as stored", %{prefix: prefix} do
      uri = "#{prefix}/supplied.md"

      :ok =
        AgentDb.write(uri, "a body",
          abstract: "a supplied abstract",
          overview: "a supplied overview"
        )

      layers = AgentDb.layers(uri)

      assert layers.abstract.text == "a supplied abstract"
      assert layers.abstract.source == :stored
      assert layers.overview.text == "a supplied overview"
      assert layers.overview.source == :stored
      assert layers.content.source == :stored
    end

    test "a missing document is an error, as any other read", %{prefix: prefix} do
      assert {:error, _} = AgentDb.layers("#{prefix}/nope.md")
    end

    test "a frontmatter identity is the abstract, not the YAML block" do
      uri = "viking://user/skill-fixture/skills/layers/SKILL.md"

      # A summary a past run stored at this URI would shadow the frontmatter
      # with generated text: the fixture must start from nothing. Removal is
      # durable against summary work still in flight for it, so the leftover
      # of both this run and any earlier one is dead before the write.
      _ = AgentDb.rm(uri)

      :ok =
        AgentDb.write(
          uri,
          "---\nname: layer-fixture\ndescription: A fixture skill for the layer reads\n---\n\n# Body text here\n"
        )

      layers = AgentDb.layers(uri)
      assert layers.abstract.text == "layer-fixture — A fixture skill for the layer reads"

      # And nothing is left behind for the next run to trip on.
      on_exit(fn -> AgentDb.rm(uri) end)
    end
  end
end
