# Proposal

## Why

AgentDb already has application workflows, explicit storage/inference/transport ports, and tests for important persistence and concurrency invariants, but runtime behavior is difficult to measure and correlate across API calls, SQLite, model inference, and durable workers. The inspection also found that document writes ignore background-job enqueue failures, the configured worker count is not used when starting workers, and hybrid-search task timeouts can escape as process exits; improving these now makes failures diagnosable and performance work evidence-based without repeating the completed architecture refactor.

## What Changes

- Establish reproducible performance baselines for core store operations and background processing; optimize only measured hot paths while retaining existing correctness and resource-safety invariants.
- Honor the already-configured background worker count and ensure document persistence plus required durable-job enqueue is one outcome: a successful write has all required jobs, while an enqueue failure leaves no partial write and returns an error that can be retried.
- Add structured, redacted logs and low-overhead runtime measurements for public operations, storage/inference boundaries, model loading, and background-job outcomes.
- Add OpenTelemetry-compatible distributed traces with W3C trace-context propagation through HTTP/WebSocket operations and durable background work; keep export configuration under the host application's control.
- Make expected operation failures, including bounded task timeouts, return classified errors without terminating callers or WebSocket connections; preserve existing API and storage consistency guarantees.
- Document the diagnostics, trace propagation, performance baselines, and operational requirements.

## Capabilities

### New Capabilities

- `runtime-observability`: Structured operational logs, low-cardinality runtime measurements, and correlated distributed traces across requests and durable background work.

### Modified Capabilities

- `context-store`: Define the consistency and error outcome when a document's required background work cannot be enqueued.
- `http-api`: Define trace-context propagation for HTTP and WebSocket operations while preserving the existing error and connection-survival contract.

## Impact

- **Code:** `AgentDb.Application` and `AgentDb.Config`; application workflows and `AgentDb.Core.Storage`; SQLite storage, queue, worker, and model-manager paths; Phoenix endpoint, controllers, and channel.
- **Dependencies/configuration:** Direct telemetry/OpenTelemetry API instrumentation; any benchmark tooling is development-only. The host chooses its OpenTelemetry SDK/exporter, avoiding a vendor or exporter lock-in.
- **Compatibility:** Preserve `AgentDb` operation signatures, existing wire payloads, and URI/error semantics except for accurately reported enqueue/timeout failures. Storage adapters must honor the existing write callback's new internal job-enqueue option; document that contract extension for custom adapters.
- **Coordination:** Keep instrumentation compatible with the in-flight `emlx-support` and `port-inference-to-bumblebee-serving` changes. Reuse the completed clean-architecture boundaries and contract tests.
