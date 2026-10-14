defmodule AgentDb.VectorIndexDriftTest do
  @moduledoc false
  # What the read path owes when the index holds rows the store does not, and
  # what the standing reclamation job does about them.
  #
  # The vector index is derived, so drift is a cost rather than a correctness
  # failure: rows for removed URIs are already invisible to search, because the
  # read path joins them away. What they still do is occupy the index, and grow
  # without anyone being told -- which is precisely how the orphan leak in
  # `harden-node-removal` stayed silent. `reclaimable` is the number that keeps
  # it from being silent again, and this file is what that number is measured on.
  #
  # Only the fake provider can be put in that state cheaply: the SQLite provider
  # removes its vec rows in the same step as the nodes, so there is no surviving
  # row to observe. `plant_vector/2` writes one directly, and the assertions are
  # that search refuses to surface it. If the read-path join is ever removed,
  # everything here fails, which is the point.
  #
  # These scenarios live here rather than in the shared contract suite because
  # how drift is manufactured differs per provider. The guarantees they assert
  # are still every provider's, and the shared contract carries the ones every
  # provider can express.

  use ExUnit.Case, async: false

  alias AgentDb.Runtime
  alias AgentDb.StorageContract.Helpers
  alias AgentDb.Test.Fakes.Storage

  @dim4 [1.0, 0.0, 0.0, 0.0]

  setup do
    Application.put_env(:agent_db, :storage_adapter, Storage)
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Storage.reset()
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok = Helpers.stop_workers()

    on_exit(fn ->
      Application.delete_env(:agent_db, :storage_adapter)
      Application.delete_env(:agent_db, :data_dir)
      AgentDb.Test.Script.clear(:fake_storage)
    end)

    :ok
  end

  # -- the read path --

  test "a row surviving for a removed URI is not returned" do
    uri = "viking://resources/drift/removed.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})

    assert {:ok, [hit]} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)
    assert hit.uri == uri

    assert :ok = Storage.remove_subtree(uri)

    # The node is gone and the vec row went with it, so the search is empty.
    assert {:ok, []} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)

    # Now plant the row the way a racing worker would have: written after the
    # removal committed. Search must still refuse it.
    :ok = Storage.plant_vector(uri, @dim4)
    assert {:ok, []} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)

    # Nothing resurrects the document itself.
    assert {:ok, nil} = Storage.get_node(uri)
  end

  test "a row naming a URI that never existed is not returned" do
    ghost = "viking://resources/drift/never-written.md"
    :ok = Storage.plant_vector(ghost, @dim4)

    assert {:ok, stats} = Storage.vector_index_stats()
    assert stats.vectors == 1

    assert {:ok, []} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)
  end

  test "a planted stale vector on a live URI carries the document's content" do
    uri = "viking://resources/drift/stale.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})

    # Station a vector the new content does not match, then search for it. A
    # write must have left no such row behind, so what is asserted is the
    # replacement the write enqueues -- and that a hit carries the document's
    # current content, not the vector's history.
    assert :ok = Storage.put_document(uri, "beta", [])
    :ok = Storage.plant_stale_vector(uri, @dim4)

    assert {:ok, [hit]} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)
    assert hit.uri == uri
    assert hit.content == "beta"
  end

  test "unhydratable candidates do not consume the result bound" do
    for n <- 1..3 do
      uri = "viking://resources/drift/kept-#{n}.md"
      assert :ok = Storage.put_document(uri, "content #{n}", [])
      :ok = Helpers.store_vectors(Storage, %{uri => @dim4})
    end

    # Plant drift so that three of the six candidates name URIs the store does
    # not hold: the index's answer is longer than the store's.
    for n <- 4..6 do
      :ok = Storage.plant_vector("viking://resources/drift/ghost-#{n}.md", @dim4)
    end

    assert {:ok, hits} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)
    assert length(hits) == 3
    assert Enum.all?(hits, &String.starts_with?(&1.uri, "viking://resources/drift/kept-"))
  end

  test "a scope without drift returns exactly what it holds" do
    for n <- 1..5 do
      uri = "viking://resources/drift/clean-#{n}.md"
      assert :ok = Storage.put_document(uri, "content #{n}", [])
      :ok = Helpers.store_vectors(Storage, %{uri => @dim4})
    end

    # Drift in a sibling subtree, not a descendant: the scope rule is
    # exact-URI-or-descendant, so this row belongs to another scope's drift and
    # must not thin this one's answer.
    :ok = Storage.plant_vector("viking://resources/drift-elsewhere/ghost.md", @dim4)

    assert {:ok, hits} =
             Storage.search_vector(Helpers.encode_vector(@dim4), 5, "viking://resources/drift")

    assert length(hits) == 5
    assert Enum.all?(hits, &String.starts_with?(&1.uri, "viking://resources/drift/clean-"))
  end

  test "a derived index does not delay a removal" do
    uri = "viking://resources/drift/delayed.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})

    # The removal completes on the node store's own terms; it does not wait for
    # the index to agree, and it does not fail because the index is behind.
    started = System.monotonic_time(:microsecond)
    assert :ok = Storage.remove_subtree(uri)
    elapsed = System.monotonic_time(:microsecond) - started

    assert {:ok, nil} = Storage.get_node(uri)
    assert {:ok, []} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)

    # Asserting a bound rather than timing the engine: the guarantee is that the
    # removal is not sequenced behind an index operation.
    assert elapsed < 100_000

    # This provider purges what it can in the same step, so the row a slower
    # provider would leave behind is planted here, the way a racing worker's
    # write would land: unsearchable at once, reclaimed afterwards.
    :ok = Storage.plant_vector(uri, @dim4)
    assert {:ok, []} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)

    assert {:ok, stats} = Storage.vector_index_stats()
    assert stats.reclaimable == 1

    assert :ok = Storage.reclaim_vector_index()
    assert {:ok, later} = Storage.vector_index_stats()
    assert later.reclaimable == 0
  end

  # -- containment --

  test "an index that raises is contained as an error the caller can act on" do
    uri = "viking://resources/drift/raises.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})

    # The fake calls the scripted function, so the raise happens inside the
    # provider the way a NIF's would. What is asserted is that the boundary
    # turns it into an error tuple rather than an exit.
    Storage.stub(:search_vector, fn _query, _scope, _dim ->
      raise ArgumentError, "the argument is wrong"
    end)

    assert {:error, :vector_index_unavailable} =
             Runtime.vector_search(Helpers.encode_vector(@dim4), 10, nil)

    # A subsequent search works again, so the raise took nothing down with it.
    Storage.stub(:search_vector, {:ok, []})
    assert {:ok, []} = Runtime.vector_search(Helpers.encode_vector(@dim4), 10, nil)
  end

  test "index backpressure is reported as retryable, not as a new failure class" do
    uri = "viking://resources/drift/busy.md"
    assert :ok = Storage.put_document(uri, "alpha", [])

    # An engine's overload is "try again later", which is the same fact the store
    # already reports for an index it cannot reach at all. The boundary maps it
    # so a caller retries rather than concluding the capability is gone.
    {:ok, :stored} =
      Storage.put_embedding_result(enqueue_and_claim(uri), uri, Helpers.encode_vector(@dim4))

    Storage.stub(:search_vector, {:error, :busy})

    assert {:error, :vector_index_unavailable} =
             Runtime.vector_search(Helpers.encode_vector(@dim4), 10, nil)
  end

  test "a classified refusal is passed through, not flattened" do
    uri = "viking://resources/drift/refusal.md"
    assert :ok = Storage.put_document(uri, "alpha", [])

    # `:dim_mismatch` and an invalid query are answers, not unavailability. The
    # boundary contains raises and overload; it must not erase what the provider
    # meant.
    Storage.stub(:search_vector, {:error, :dim_mismatch})

    assert {:error, :dim_mismatch} = Runtime.vector_search(Helpers.encode_vector(@dim4), 10, nil)
  end

  defp enqueue_and_claim(uri) do
    {:ok, job_id} = Storage.enqueue_job(:embed, %{uri: uri, content: "alpha"})
    {:ok, _job} = Storage.dequeue_job([:embed])
    job_id
  end

  # -- drift, reported --

  test "drift is reported rather than hidden" do
    # The lesson `harden-node-removal` recorded: the JOIN that hid orphans from
    # results also hid the leak itself. The count is what makes it visible.
    assert {:ok, clean} = Storage.vector_index_stats()
    assert clean.reclaimable == 0

    :ok = Storage.put_document("viking://resources/drift/visible.md", "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{"viking://resources/drift/visible.md" => @dim4})
    :ok = Storage.plant_vector("viking://resources/drift/orphan.md", @dim4)

    assert {:ok, drifted} = Storage.vector_index_stats()
    # Two rows are indexed; one names a URI the store cannot hold.
    assert drifted.vectors == 2
    assert drifted.reclaimable == 1
  end

  test "a removal's drift is reported before it is reclaimed" do
    uri = "viking://resources/drift/leave-behind.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})
    assert :ok = Storage.remove_subtree(uri)

    # Removal purges what it can, but the read-path join is what the guarantee
    # rests on, so a row written after the removal committed is drift the store
    # still holds. Planted here the way a racing worker's write would land.
    :ok = Storage.plant_vector(uri, @dim4)

    assert {:ok, stats} = Storage.vector_index_stats()
    assert stats.reclaimable == 1

    assert :ok = Storage.reclaim_vector_index()

    assert {:ok, later} = Storage.vector_index_stats()
    assert later.reclaimable == 0
    assert later.vectors == 0
  end

  # -- reclamation --

  test "reclamation deletes drift and keeps what the store holds" do
    uri = "viking://resources/drift/kept.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})
    :ok = Storage.plant_vector("viking://resources/drift/orphan.md", @dim4)

    assert {:ok, drifted} = Storage.vector_index_stats()
    assert drifted.reclaimable == 1

    assert :ok = Storage.reclaim_vector_index()

    assert {:ok, reclaimed} = Storage.vector_index_stats()
    assert reclaimed.reclaimable == 0
    assert reclaimed.vectors == 1

    # The live row is untouched, and still searchable.
    assert {:ok, [hit]} = Storage.search_vector(Helpers.encode_vector(@dim4), 10, nil)
    assert hit.uri == uri
  end

  test "reclaiming a clean store is a no-op" do
    uri = "viking://resources/drift/clean.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => @dim4})

    assert :ok = Storage.reclaim_vector_index()
    assert :ok = Storage.reclaim_vector_index()

    assert {:ok, stats} = Storage.vector_index_stats()
    assert stats.reclaimable == 0
    assert stats.vectors == 1
  end
end
