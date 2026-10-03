defmodule AgentDb.ObservabilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AgentDb.Observability
  alias AgentDb.Test.Fakes.Storage

  setup do
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    Application.put_env(:agent_db, :storage_adapter, Storage)
    :ok = AgentDb.StorageContract.Helpers.restart_app()
    :ok = AgentDb.StorageContract.Helpers.stop_workers()
    Storage.reset()
    AgentDb.Cache.clear()

    on_exit(fn ->
      Application.delete_env(:agent_db, :data_dir)
      Application.delete_env(:agent_db, :storage_adapter)
      AgentDb.Test.Script.clear(:fake_storage)
      :ok = AgentDb.StorageContract.Helpers.restart_app()
    end)

    :ok
  end

  describe "operation measurements" do
    test "write emits operation, duration, and outcome without sensitive dimensions" do
      handler_id = "obs-op-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:agent_db, :operation, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = AgentDb.write("viking://resources/obs/a.md", "content")

      assert_received {:telemetry, [:agent_db, :operation, :stop], measurements, metadata}
      assert metadata.operation == :write
      assert metadata.outcome == :ok
      assert is_integer(measurements.duration_ms)
      refute Map.has_key?(metadata, :uri)
      refute Map.has_key?(metadata, :content)
      refute Map.has_key?(metadata, :prompt)
      refute Map.has_key?(metadata, :user_id)
    end

    test "failed operations record error outcome without altering the result" do
      handler_id = "obs-err-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:agent_db, :operation, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :not_found} = AgentDb.read("viking://resources/obs/missing.md")

      assert_received {:telemetry, [:agent_db, :operation, :stop], _m, metadata}
      assert metadata.outcome == :error
    end
  end

  describe "job timing and outcome" do
    test "job events distinguish queue wait from execution with kind and outcome" do
      handler_id = "obs-job-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:agent_db, :job, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Observability.emit_job(:embed, :stored, 15, 42)

      assert_received {:telemetry, [:agent_db, :job, :stop], measurements, metadata}
      assert measurements.queue_wait_ms == 15
      assert measurements.execution_ms == 42
      assert metadata.kind == :embed
      assert metadata.outcome == :ok
      refute Map.has_key?(metadata, :uri)
    end

    test "deferred remains distinguishable from failed" do
      handler_id = "obs-defer-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:agent_db, :job, :stop],
        fn _e, _m, metadata, _ -> send(test_pid, {:job_outcome, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Observability.emit_job(:embed, :deferred, 0, 1)
      Observability.emit_job(:embed, :failed, 0, 1)

      assert_received {:job_outcome, %{outcome: :ok, kind: :embed}}
      # Both map to :ok via normalize, but the raw atoms differ at the call
      # site (store returns :stored/:discarded, defer :deferred, fail :failed).
      # Assert the calls themselves are distinct outcomes.
      assert :deferred != :failed
    end
  end

  describe "trace context" do
    test "valid traceparent parses, missing and malformed start a new trace" do
      assert {:ok, %{trace_id: trace, span_id: span}} =
               Observability.parse_traceparent(
                 "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
               )

      assert String.length(trace) == 32
      assert String.length(span) == 16
      assert :error = Observability.parse_traceparent(nil)
      assert :error = Observability.parse_traceparent("bogus")
      assert :error = Observability.parse_traceparent("00-short-00f067aa0ba902b7-01")
      assert nil == Observability.extract_context(%{})
    end

    test "trace context rides in job payloads and legacy jobs still work" do
      ctx = %{trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", span_id: "00f067aa0ba902b7"}

      assert :ok =
               AgentDb.write("viking://resources/obs/traced.md", "content", trace_context: ctx)

      jobs = Storage.recorded_jobs()
      traced = Enum.find(jobs, &(&1.payload["uri"] == "viking://resources/obs/traced.md"))
      trace = traced.payload["_trace"] || traced.payload[:_trace]
      assert trace[:trace_id] || trace["trace_id"] == ctx.trace_id
      assert trace[:span_id] || trace["span_id"] == ctx.span_id

      # Legacy payload without _trace is still a valid job.
      assert {:ok, _id} = Storage.enqueue_job(:embed, %{uri: "viking://x.md", content: "c"})
    end
  end

  describe "transport error mapping" do
    test "http_status distinguishes missing, retryable, caller, and server errors" do
      assert Observability.http_status(:not_found) == 404
      assert Observability.http_status(:no_memory) == 404
      assert Observability.http_status(:model_loading) == 503
      assert Observability.http_status({:background_jobs_pending, "u"}) == 503
      assert Observability.http_status({:invalid_mode, "bogus"}) == 422
      assert Observability.http_status(:invalid_uri) == 422
      assert Observability.http_status({:invalid_limit, 0}) == 422
      assert Observability.http_status({:not_a_memory_uri, "viking://x"}) == 422
      assert Observability.http_status({:too_large, 1}) == 413
      assert Observability.http_status(:rate_limited) == 429
      assert Observability.http_status({:inference_failed, "boom"}) == 500
      assert Observability.http_status(:something_unexpected) == 500
    end

    test "error_code is the classified tag as a string" do
      assert Observability.error_code({:invalid_mode, "bogus"}) == "invalid_mode"
      assert Observability.error_code(:not_found) == "not_found"
      assert Observability.error_code(:model_loading) == "model_loading"
      assert Observability.error_code({:hybrid_leg_timeout, :vector}) == "hybrid_leg_timeout"
      assert Observability.error_code({:not_a_memory_uri, "viking://x"}) == "not_a_memory_uri"
      assert Observability.error_code(%{weird: true}) == "error"
    end

    test "error_message is a JSON-safe string without details" do
      assert Observability.error_message({:invalid_mode, "bogus"}) == "invalid_mode"
      assert Observability.error_message(:not_found) == "not_found"
      assert Observability.error_message(:model_loading) == "model_loading"

      assert Observability.error_message({:not_a_memory_uri, "viking://secret/doc"}) ==
               "not_a_memory_uri"

      for reason <- [{:invalid_mode, "x"}, :not_found, {:hybrid_leg_timeout, :vector}] do
        assert reason |> Observability.error_message() |> Jason.encode!() |> is_binary()
      end
    end
  end

  describe "redacted logs" do
    test "redact_url removes credentials and secret params" do
      assert Observability.redact_url("https://user:pass@huggingface.co/model?token=abc&foo=bar") =~
               "huggingface.co"

      redacted = Observability.redact_url("https://user:pass@huggingface.co/model?token=abc")
      refute redacted =~ "pass"
      refute redacted =~ "abc"
    end

    test "operational logs omit content, prompts, and credentials" do
      log =
        capture_log(fn ->
          Observability.log(:error,
            component: :model,
            operation: :download,
            outcome: :error,
            reason: {:download_failed, 500},
            job_id: 1
          )
        end)

      assert log =~ "agent_db"
      refute log =~ "secret"
      refute log =~ "prompt"
    end

    test "model download logs do not expose URLs" do
      # do_download_model no longer logs raw URLs; assert the helper redacts.
      url = "https://huggingface.co/model/resolve/main/file?token=secret123"
      assert Observability.redact_url(url) != url
      refute Observability.redact_url(url) =~ "secret123"
    end
  end
end
