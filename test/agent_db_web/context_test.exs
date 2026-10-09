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
