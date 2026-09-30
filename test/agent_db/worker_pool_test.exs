defmodule AgentDb.WorkerPoolTest do
  use ExUnit.Case, async: false

  alias AgentDb.Workers.{Embedding, Summarization}

  setup do
    original = :application.get_env(:agent_db, :job_workers, nil)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:agent_db, :job_workers),
        else: Application.put_env(:agent_db, :job_workers, original)
    end)

    :ok
  end

  test "builds the configured count for both job families with unique IDs" do
    Application.put_env(:agent_db, :job_workers, 3)
    specs = AgentDb.Application.worker_specs()

    assert length(specs) == 6

    ids = Enum.map(specs, & &1.id)
    assert length(Enum.uniq(ids)) == 6

    embedding_ids = for {Embedding, _n} = id <- ids, do: id
    summarization_ids = for {Summarization, _n} = id <- ids, do: id
    assert length(embedding_ids) == 3
    assert length(summarization_ids) == 3
  end

  test "startup rejects a non-positive count" do
    Application.put_env(:agent_db, :job_workers, 0)

    assert_raise ArgumentError, ~r/job_workers must be a positive integer/, fn ->
      AgentDb.Application.worker_specs()
    end

    Application.put_env(:agent_db, :job_workers, -2)

    assert_raise ArgumentError, ~r/job_workers must be a positive integer/, fn ->
      AgentDb.Application.worker_specs()
    end
  end

  test "registrations are unique per index" do
    assert Embedding.registration(1) != Embedding.registration(2)
    assert Summarization.registration(1) != Summarization.registration(2)
    assert Embedding.registration() == "embedding_worker_1"
    assert Summarization.registration() == "summarization_worker_1"
  end
end
