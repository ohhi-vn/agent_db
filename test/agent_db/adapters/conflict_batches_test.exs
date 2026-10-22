defmodule AgentDb.Adapters.ConflictBatchesTest do
  use ExUnit.Case, async: false

  # The conflict read's pair evaluation is pure enough to test without a
  # vector index: this host has no sqlite-vec extension, so a store-backed
  # test can never hand the batched comparison real vectors. What deserves
  # verifying all the same -- batches scored exactly once, orientation, the
  # similarity floor, and same-type discipline -- proves from blobs alone.

  alias AgentDb.Adapters.SQLite

  defp enc(vec), do: for(x <- vec, into: <<>>, do: <<x::float-32>>)

  defp rows(uris), do: Enum.map(uris, &%{uri: &1})

  defp blobs(pairs), do: Map.new(pairs, fn {uri, vec} -> {uri, enc(vec)} end)

  # Zero-padded so URI order equals the numeric order the batches walk.
  defp uri(n) do
    "viking://user/memories/preferences/branch#{String.pad_leading(Integer.to_string(n), 3, "0")}"
  end

  # A basis vector on axis `n` counted from 5: orthogonal to every other
  # basis vector, and to the 4-component vectors the near-pairs use, whose
  # span is axes 1..4.
  defp basis(n), do: Enum.map(1..(129 + 4), &if(&1 == n + 4, do: 1.0, else: 0.0))

  defp last_segment(uri) do
    uri
    |> String.split("/")
    |> List.last()
    |> String.trim_leading("branch")
    |> String.to_integer()
  end

  test "near-identical same-type vectors are reported, others are not" do
    a = uri(1)
    b = uri(2)
    c = uri(3)
    other = "viking://user/memories/events/branch001"

    vectors =
      blobs([
        {a, [1.0, 0.0, 0.0, 0.0]},
        {b, [0.99, 0.01, 0.0, 0.0]},
        {c, [0.0, 1.0, 0.0, 0.0]},
        # The identical value filed under another type: never paired with a.
        {other, [1.0, 0.0, 0.0, 0.0]}
      ])

    assert [%{uri_a: first, uri_b: second, similarity: sim}] =
             SQLite.similar_pairs(rows([a, b, c, other]), vectors)

    assert first == a
    assert second == b
    assert sim > 0.9
  end

  test "pairs crossing a batch boundary are scored exactly once" do
    # 129 URIs walk the batches as [1..64], [65..128], [129]. The neighbours
    # of branch065 are near-identical to one another: branch064 sits in the
    # previous batch, branch066 sits beside branch065, so one pair crosses a
    # boundary and one stays inside a batch, and each is scored exactly once.
    # Every other vector is an axis of its own, and nothing else can reach
    # the floor.
    uris = Enum.map(1..129, &uri/1)

    vectors =
      uris
      |> Enum.map(&{&1, enc(basis(last_segment(&1)))})
      |> Map.new()
      |> Map.merge(%{
        uri(64) => enc([0.98, 0.02, 0.0, 0.0]),
        uri(65) => enc([0.99, 0.01, 0.0, 0.0]),
        uri(66) => enc([1.0, 0.0, 0.0, 0.0])
      })

    pairs = SQLite.similar_pairs(rows(uris), vectors)

    # The three expected pairs and no others, in their canonical orientation.
    assert Enum.sort(Enum.map(pairs, &[&1.uri_a, &1.uri_b])) == [
             [uri(64), uri(65)],
             [uri(64), uri(66)],
             [uri(65), uri(66)]
           ]

    # Reported most-similar first, and one record per pair.
    assert Enum.map(pairs, & &1.similarity) ==
             Enum.sort(Enum.map(pairs, & &1.similarity), :desc)

    assert Enum.all?(pairs, &(&1.similarity > 0.99))
  end
end
