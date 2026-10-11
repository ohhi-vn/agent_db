defmodule AgentDbWeb.ContextTest do
  @moduledoc """
  The transport's error rendering.

  A page must describe a store failure in the store's own vocabulary rather than
  printing the failure term, so `error_message/1` is the one place the web layer
  asks for that word. These pin it to the shared taxonomy.
  """
  use ExUnit.Case, async: true

  alias AgentDbWeb.Context

  test "classifies a tagged reason to its taxonomy word" do
    assert Context.error_message({:invalid_uri, "viking://"}) == "invalid_uri"
  end

  test "classifies a bare atom reason" do
    assert Context.error_message(:not_found) == "not_found"
  end

  test "does not echo the detail of a failure" do
    message = Context.error_message({:unsafe_path, "viking://resources/../secret"})

    assert message == "unsafe_path"
    refute message =~ "secret"
  end

  test "falls back to a stable word for an unrecognised reason" do
    assert Context.error_message({"not an atom", 1}) == "error"
  end
end

defmodule AgentDbWeb.ContextLayersTest do
  @moduledoc """
  The console's LLM layer view reads through one facade accessor.

  `get_layers/1` reports exactly what the store answers for abstract,
  overview, and read, plus whether each layer was stored or derived at read
  time, so the console never reimplements the fallback.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Cache
  alias AgentDbWeb.Context

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
    end)

    :ok
  end

  test "stored layers report stored source with text and char count" do
    :ok =
      AgentDb.write("viking://resources/layers/stored.md", "full L2 body",
        abstract: "one-line L0",
        overview: "structured L1"
      )

    layers = Context.get_layers("viking://resources/layers/stored.md")

    assert %{text: "one-line L0", source: :stored, chars: 11} = layers.l0
    assert %{text: "structured L1", source: :stored, chars: 13} = layers.l1
    assert %{text: "full L2 body", source: :stored, chars: 12} = layers.l2
  end

  test "missing layers fall back to content-derived text" do
    :ok = AgentDb.write("viking://resources/layers/fallback.md", "first line\nsecond line")

    layers = Context.get_layers("viking://resources/layers/fallback.md")

    assert %{text: "first line", source: :fallback} = layers.l0
    assert %{text: "first line\nsecond line", source: :fallback} = layers.l1
    assert %{text: "first line\nsecond line", source: :stored} = layers.l2
    assert layers.l0.chars == String.length("first line")
  end

  test "a frontmatter skill shows identity at L0 and body at L1" do
    content = """
    ---
    name: easy-rpc
    description: Guidance for wrapping remote procedure calls.
    ---

    # easy-rpc

    Body content for the skill.
    """

    :ok = AgentDb.write("viking://user/alice/skills/easy-rpc/SKILL.md", content)

    layers = Context.get_layers("viking://user/alice/skills/easy-rpc/SKILL.md")

    assert %{text: "easy-rpc — Guidance for wrapping remote procedure calls.", source: :fallback} =
             layers.l0

    assert %{source: :fallback} = layers.l1
    refute layers.l1.text =~ "name:"
    refute layers.l1.text =~ "description:"
    assert layers.l1.text =~ "Body content"
    assert layers.l0.chars == String.length(layers.l0.text)
    assert layers.l1.chars == String.length(layers.l1.text)
  end

  test "a missing document reports every layer unavailable" do
    layers = Context.get_layers("viking://resources/layers/missing.md")

    assert %{text: "", source: :unavailable, chars: 0} = layers.l0
    assert %{text: "", source: :unavailable, chars: 0} = layers.l1
    assert %{text: "", source: :unavailable, chars: 0} = layers.l2
  end

  test "an invalid URI reports every layer unavailable without raising" do
    layers = Context.get_layers("http://nope/x")

    assert %{text: "", source: :unavailable, chars: 0} = layers.l0
    assert %{text: "", source: :unavailable, chars: 0} = layers.l1
    assert %{text: "", source: :unavailable, chars: 0} = layers.l2
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end
end
