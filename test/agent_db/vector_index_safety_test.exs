defmodule AgentDb.VectorIndexSafetyTest do
  @moduledoc false
  # Dim-safety logic through the emulated namespaced index: routing, refusal,
  # backfill, prune, and coverage run deterministically on any host. The vec0
  # SQL itself still needs an extension host; this file covers everything the
  # application layer promises around it.
  use ExUnit.Case, async: false

  alias AgentDb.StorageContract.Helpers
  alias AgentDb.Test.Fakes.Storage

  setup do
    Application.put_env(:agent_db, :storage_adapter, Storage)
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Storage.reset()
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)

    on_exit(fn ->
      Application.delete_env(:agent_db, :storage_adapter)
      Application.delete_env(:agent_db, :data_dir)
      AgentDb.Test.Script.clear(:fake_storage)
    end)

    :ok
  end

  test "mixed dims land apart and the active dim serves while others refuse" do
    a = "viking://resources/dims/a.md"
    b = "viking://resources/dims/b.md"
    assert :ok = Storage.put_document(a, "alpha", [])
    assert :ok = Storage.put_document(b, "beta", [])

    :ok = Helpers.store_vectors(Storage, %{a => [1.0, 0.0, 0.0, 0.0], b => [1.0, 0.0]})

    # Active is dim 2 (last write): its query serves, the other dim refuses.
    assert {:ok, [hit_b]} = Storage.search_vector(Helpers.encode_vector([1.0, 0.0]), 10, nil)
    assert hit_b.uri == b

    assert {:error, :dim_mismatch} =
             Storage.search_vector(Helpers.encode_vector([1.0, 0.0, 0.0, 0.0]), 10, nil)

    # Rewriting dim 4 flips the active table; the dim-2 row is untouched.
    :ok = Helpers.store_vectors(Storage, %{a => [1.0, 0.0, 0.0, 0.0]})

    assert {:ok, [hit_a]} = Storage.search_vector(Helpers.encode_vector([1.0, 0.0, 0.0, 0.0]), 10, nil)
    assert hit_a.uri == a

    assert {:error, :dim_mismatch} = Storage.search_vector(Helpers.encode_vector([1.0, 0.0]), 10, nil)

    # Backfill for the active dim still wants b: proof b never leaked into it.
    assert {:ok, 1} = Storage.backfill_vector_index()
  end

  test "absurd dims are refused and distinct dims are capped" do
    uri = "viking://resources/dims/capped.md"
    assert :ok = Storage.put_document(uri, "capped", [])

    {:ok, job_id} = Storage.enqueue_job(:embed, %{uri: uri, content: ""})
    {:ok, _} = Storage.dequeue_job([:embed])
    assert {:error, {:invalid_dim, _}} = Storage.put_embedding_result(job_id, uri, <<1, 2, 3>>)

    for n <- 1..16 do
      doc = "viking://resources/dims/cap-#{n}.md"
      assert :ok = Storage.put_document(doc, "filler", [])
      :ok = Helpers.store_vectors(Storage, %{doc => List.duplicate(0.0, n)})
    end

    {:ok, job_id} = Storage.enqueue_job(:embed, %{uri: uri, content: ""})
    {:ok, _} = Storage.dequeue_job([:embed])
    oversized = :binary.copy(<<0::float-32>>, 17)

    assert {:error, :too_many_dims} = Storage.put_embedding_result(job_id, uri, oversized)
  end

  test "backfill enqueues only URIs missing in the active table" do
    a = "viking://resources/backfill/a.md"
    b = "viking://resources/backfill/b.md"
    assert :ok = Storage.put_document(a, "alpha", [])
    assert :ok = Storage.put_document(b, "beta", [])
    :ok = Helpers.store_vectors(Storage, %{a => [1.0, 0.0, 0.0, 0.0]})

    assert {:ok, 1} = Storage.backfill_vector_index()

    claimed = Helpers.drain_jobs(Storage, [:embed])
    assert [%{payload: %{"uri" => ^b}}] = claimed
  end

  test "prune refuses the active dim and drops the rest" do
    a = "viking://resources/prune/a.md"
    assert :ok = Storage.put_document(a, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{a => [1.0, 0.0, 0.0, 0.0]})

    assert {:error, :active_dim} = Storage.prune_vector_index(4)
    assert {:error, {:invalid_dim, _}} = Storage.prune_vector_index(0)
    assert :ok = Storage.prune_vector_index(2)

    assert {:ok, stats} = Storage.vector_index_stats()
    assert stats.active_dim == 4
  end

  test "coverage tracks active dim, counts, and backfill need" do
    assert {:ok, fresh} = Storage.vector_index_stats()
    assert fresh == %{available: true, active_dim: :unknown, vectors: 0, documents: 0, needs_backfill: false}

    a = "viking://resources/coverage/a.md"
    b = "viking://resources/coverage/b.md"
    assert :ok = Storage.put_document(a, "alpha", [])
    assert :ok = Storage.put_document(b, "beta", [])

    assert {:ok, nodims} = Storage.vector_index_stats()
    assert nodims.active_dim == :unknown
    assert nodims.needs_backfill == true

    :ok = Helpers.store_vectors(Storage, %{a => [1.0, 0.0, 0.0, 0.0]})
    assert {:ok, partial} = Storage.vector_index_stats()
    assert partial == %{available: true, active_dim: 4, vectors: 1, documents: 2, needs_backfill: true}

    :ok = Helpers.store_vectors(Storage, %{b => [0.0, 1.0, 0.0, 0.0]})
    assert {:ok, full} = Storage.vector_index_stats()
    assert full.needs_backfill == false
  end

  test "removal purges vectors in every dim" do
    uri = "viking://resources/gone/a.md"
    assert :ok = Storage.put_document(uri, "alpha", [])
    :ok = Helpers.store_vectors(Storage, %{uri => [1.0, 0.0, 0.0, 0.0]})

    assert :ok = Storage.remove_subtree("viking://resources/gone")

    assert {:ok, stats} = Storage.vector_index_stats()
    assert stats.vectors == 0
  end
end
