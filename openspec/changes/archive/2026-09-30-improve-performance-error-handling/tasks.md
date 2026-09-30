# Tasks

## 1. Error mapping (reproduce, then fix)

- [x] 1.1 Reproduce each README Known-issues HTTP case against a running daemon and verify which still fail, closing already-fixed notes instead of re-fixing them
- [x] 1.2 Unify transport error rendering through the shared `Observability` classification with JSON-safe bodies and correct 4xx/5xx statuses, and verify invalid modes, scopes, limits, and queries return 4xx on REST, WebSocket, MCP, and CLI without terminating the caller
- [x] 1.3 Add bounded machine-readable `code` to every transport error response with no URIs, content, prompts, users, or credentials in payloads, and verify codes match telemetry classification for the same failures

## 2. Bench-driven hot paths

- [x] 2.1 Profile write, keyword search, and tree projection with `mix run bench/agent_db_bench.exs` on one host and verify the profile names the dominant cost in each path before changing code
- [x] 2.2 Optimize the profiled hot paths keeping all facade contracts unchanged and verify each retained change shows a repeatable delta vs `bench/baseline.md` with memory unchanged, dropping unproven changes

## 3. Inference concurrency and queue resilience

- [x] 3.1 Parallelize `ModelManager` inference behind the unchanged `embed/1`/`summarize/2` contracts preserving grace-period, retry, and `:model_loading` semantics, and verify with warmed models plus full `mix test` and a soak run
- [x] 3.2 Tune worker and queue behavior (timeouts, backpressure, retry budgets) keeping existing write-outcome and rescheduling contracts, and verify queue drain improves under load with no outcome-contract violations

## 4. Close-out

- [x] 4.1 Update `bench/baseline.md` with measured deltas only and correct the README Known-issues section for closed defects, and verify `openspec validate "improve-performance-error-handling" --strict` passes
