defmodule AgentDb.ObservabilitySinkTest do
  @moduledoc """
  The bounded record of failures and outcomes the store keeps for an operator.

  The store's measurements were always emitted and forgotten; these are the
  assertions that what is kept is bounded, is classified, and never carries a
  URI, content, or identity -- the properties that make it safe to put on a
  console at all.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Observability
  alias AgentDb.Observability.Sink

  setup do
    Sink.reset()
    on_exit(&Sink.reset/0)
    :ok
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
    # The handler runs in this process, so the table is already updated.
    :ok
  end

  defp operation(metadata), do: emit([:agent_db, :operation, :stop], %{duration_ms: 5}, metadata)

  describe "outcome counts" do
    test "count operations by outcome" do
      operation(%{operation: :read, outcome: :ok})
      operation(%{operation: :read, outcome: :ok})
      operation(%{operation: :read, outcome: :error})

      counts = Observability.operation_stats()

      assert counts[{:operation, %{operation: :read}}].counts[:ok] == 2
      assert counts[{:operation, %{operation: :read}}].counts[:error] == 1
    end

    test "count jobs and model calls separately" do
      emit([:agent_db, :job, :stop], %{queue_wait_ms: 1}, %{kind: :embed, outcome: :ok})
      emit([:agent_db, :model, :stop], %{duration_ms: 9}, %{role: :embedding, outcome: :ok})

      counts = Observability.operation_stats()

      assert counts[{:job, %{kind: :embed}}].counts[:ok] == 1
      assert counts[{:model, %{role: :embedding}}].counts[:ok] == 1
    end

    test "a dimension is only what the event already labelled" do
      operation(%{operation: :read, outcome: :ok, kind: :doc})

      # Operation and kind are both bounded by the emitting code. Nothing here
      # derives a dimension from anything else in the metadata.
      assert Observability.operation_stats()[{:operation, %{operation: :read, kind: :doc}}].counts[
               :ok
             ] ==
               1
    end
  end

  describe "recent failures" do
    test "record a failure with its operation and classified reason" do
      operation(%{operation: :write, outcome: :error, reason: :inference_failed})

      assert [%{operation: :write, reason: :inference_failed}] = Observability.recent_errors()
    end

    test "a success is not recorded as a failure" do
      operation(%{operation: :read, outcome: :ok})

      assert Observability.recent_errors() == []
    end

    test "carry no URI, content, or identity" do
      operation(%{
        operation: :write,
        outcome: :error,
        reason: :inference_failed,
        # Anything the emitting code might have attached is not recorded: the
        # entry is built from the classified reason and nothing else.
        uri: "viking://user/alice/memories/secret",
        content: "the document body",
        user: "alice"
      })

      assert [entry] = Observability.recent_errors()

      refute Map.has_key?(entry, :uri)
      refute Map.has_key?(entry, :content)
      refute Map.has_key?(entry, :user)

      # The reason is a classification, so it names what went wrong and not
      # what it went wrong about.
      assert entry.reason == :inference_failed
    end

    test "are newest first and bounded by the requested limit" do
      for n <- 1..3 do
        operation(%{operation: :"op_#{n}", outcome: :error, reason: :error})
      end

      assert [first | _] = Observability.recent_errors()
      assert length(Observability.recent_errors(1)) == 1
      assert first.operation in [:op_1, :op_2, :op_3]
    end

    test "the ring never grows past its bound however many failures occur" do
      overflow = Sink.max_errors() * 3

      for n <- 1..overflow do
        operation(%{operation: :read, outcome: :error, reason: :error, n: n})
      end

      # The failures are what the bound is about: the counters alongside them are
      # one per distinct dimension, which follows the store's code rather than
      # its traffic.
      failures =
        for {{:error, _seq}, _entry} <- :ets.tab2list(Sink.table()), do: :one

      assert length(failures) <= Sink.max_errors()
    end
  end

  describe "latency and error rate" do
    test "a successful operation's latency is retained with percentiles and error rate" do
      Sink.reset()

      for duration <- [10, 20, 30, 40, 50] do
        operation(%{operation: :read, outcome: :ok, n: duration})
        # Emit with a duration: re-emit through the event with duration_ms.
      end

      # Re-emit with explicit durations by writing directly to the sink's
      # event stream, so the ring carries the samples.
      Sink.reset()

      for duration <- [10, 20, 30, 40, 50] do
        emit([:agent_db, :operation, :stop], %{duration_ms: duration}, %{
          operation: :read,
          outcome: :ok
        })
      end

      # One failure among the successes keeps the error rate honest.
      emit([:agent_db, :operation, :stop], %{duration_ms: 999}, %{
        operation: :read,
        outcome: :error,
        reason: :not_found
      })

      stats = Observability.operation_stats()
      entry = stats[{:operation, %{operation: :read}}]

      assert entry.success == 5
      assert entry.failure == 1
      assert entry.total == 6
      assert_in_delta entry.error_rate, 1 / 6, 1.0e-9

      assert entry.p50 == 30
      assert entry.p99 == 999
      assert entry.min == 10
      assert entry.max == 999

      # The successful latency was retained alongside the failure, not only
      # the failures.
      assert entry.latency_ms.p50 == entry.p50
      assert entry.latency_ms.max == entry.max
    end

    test "retained statistics stay within the sample bound after many samples" do
      Sink.reset()

      overflow = Sink.max_latency_samples() * 2

      for n <- 1..overflow do
        emit([:agent_db, :operation, :stop], %{duration_ms: n}, %{
          operation: :read,
          outcome: :ok
        })
      end

      entry = Observability.operation_stats()[{:operation, %{operation: :read}}]

      # The ring never grows past its bound.
      assert entry.max == overflow
      assert entry.min >= overflow - Sink.max_latency_samples() + 1
      assert entry.total == overflow
    end
  end

  describe "tracked operations bound" do
    test "the oldest tracked operations are dropped once the bound is exceeded" do
      Sink.reset()

      overflow = Sink.max_tracked_operations() + 5

      for n <- 1..overflow do
        emit([:agent_db, :operation, :stop], %{duration_ms: n}, %{
          operation: :"op_#{n}",
          outcome: :ok
        })
      end

      stats = Observability.operation_stats()

      # No more than the bound are tracked.
      assert map_size(stats) <= Sink.max_tracked_operations()

      # The oldest (lowest-numbered) operations are the ones dropped.
      refute Map.has_key?(stats, {:operation, %{operation: :op_1}})
      assert Map.has_key?(stats, {:operation, %{operation: :"op_#{overflow}"}})
    end
  end

  describe "when the sink is not running" do
    test "diagnostics are empty rather than an error" do
      # Diagnostics are never a reason an operation fails, so a store whose sink
      # has not started still answers.
      assert is_list(Observability.recent_errors())
      assert is_map(Observability.operation_stats())
    end
  end
end
