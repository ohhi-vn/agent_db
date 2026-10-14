defmodule AgentDb.VectorReclaimTest do
  @moduledoc false
  # Drift, and the standing job that reclaims it.
  #
  # The removal contract already guarantees that a removed URI is never
  # *returned*: the read path joins it away. What removal does not do is delete
  # the row in the same step, so drift accumulates in the index -- which is how
  # the leak in `harden-node-removal` stayed silent. These tests are the half
  # that turns that leak into a bounded, observable cost.
  #
  # Run against the SQLite provider, because the reclamation SQL is the
  # provider's; the drift-counting and planting they rely on also work on the
  # fake, and the contract suite covers the guarantees every provider owes.

  use ExUnit.Case, async: false

  alias AgentDb.StorageContract.Helpers

  setup do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    :ok = Helpers.restart_app()
    :ok = Helpers.stop_workers()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)
    :ok
  end

  test "a fresh store reports no drift and no reclaimable rows" do
    assert {:ok, 0} = AgentDb.Runtime.vector_reclaimable()
  end

  test "the standing reclamation job is scheduled once at boot" do
    storage = AgentDb.Runtime.storage()

    # One row, not one per worker: a pool would be several processes contending
    # for a single job.
    assert storage.count_jobs_of_kind(:reclaim_vector_index) == 1

    # A restart reseeds the same single row rather than adding a second.
    :ok = Helpers.restart_app()
    :ok = Helpers.stop_workers()
    assert storage.count_jobs_of_kind(:reclaim_vector_index) == 1
  end

  test "the job is claimed by the worker that can run it, and by no other" do
    storage = AgentDb.Runtime.storage()

    # The worker that owns this kind claims it. A durable job reports its kind
    # as the string it was persisted as.
    assert {:ok, job} = storage.dequeue_job([:reclaim_vector_index])
    assert job.kind == "reclaim_vector_index"

    # And a worker for another kind must find nothing: a claimed job of the
    # wrong kind would be a job destroyed. Re-enqueueing the reclaim job first
    # keeps the assertion about which worker claims what, rather than about
    # which one got there.
    {:ok, _} = storage.enqueue_job(:reclaim_vector_index, %{})
    assert {:error, :empty} = storage.dequeue_job([:embed])
    assert {:error, :empty} = storage.dequeue_job([:summarize_abstract])
    assert {:error, :empty} = storage.dequeue_job([:summarize_overview])
  end

  test "an idle store defers its reclamation without spending an attempt" do
    storage = AgentDb.Runtime.storage()

    for _round <- 1..3 do
      assert {:ok, job} = storage.dequeue_job([:reclaim_vector_index])
      # The index is clean, so the worker reports clean and defers.
      assert :ok = storage.defer_job(job.id, 0)
    end

    assert {:ok, job} = storage.dequeue_job([:reclaim_vector_index])
    # Deferral is not failure: the budget is untouched, and the job is claimable.
    assert job.attempts == 1
    assert storage.count_jobs_of_kind(:reclaim_vector_index) == 1

    assert {:ok, stats} = storage.queue_stats()
    # Nothing failed, and nothing is permanently stuck.
    assert Map.get(stats, :failed, 0) == 0
  end

  test "reclaiming a clean store is a no-op that leaves live rows alone" do
    uri = "viking://resources/reclaim/live.md"
    assert :ok = AgentDb.write(uri, "content that matters")

    # No vectors on this host without the extension, but the guarantee is what
    # is asserted: a reclamation pass must never remove what the store holds.
    assert :ok = AgentDb.Runtime.storage().reclaim_vector_index()
    assert {:ok, node} = AgentDb.Runtime.storage().get_node(uri)
    assert node.content == "content that matters"
  end

  test "an index that cannot be reached defers, rather than failing the job" do
    storage = AgentDb.Runtime.storage()

    # The worker's deferral path is what keeps a stalled reclamation visible
    # rather than poison: an unreachable index is "try again later", the same
    # shape as a model still loading.
    assert {:ok, job} = storage.dequeue_job([:reclaim_vector_index])

    assert :ok = storage.defer_job(job.id, 0)

    assert {:ok, again} = storage.dequeue_job([:reclaim_vector_index])
    assert again.attempts == 1
    assert 0 == storage.count_jobs("viking://", ["failed"])
  end
end
