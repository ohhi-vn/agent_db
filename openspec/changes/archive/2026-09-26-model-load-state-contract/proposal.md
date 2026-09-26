# Proposal

## Why

Model loading now works (`fix-model-loading`), which makes the *next* problem measurable rather than theoretical. Loading is lazy, and the numbers on a stock `all-MiniLM-L6-v2` are:

| | |
|---|---|
| cold load — download + load | 36,929ms |
| warm load — cached weights | 3,286–3,649ms |
| default `GenServer.call` budget | 5,000ms |
| `model_status` while a load runs | 3,663ms — unavailable |
| job retry budget | ~15s wall clock (5 attempts: 1+2+4+8) |

Three consequences, none of which the current contract can express.

**The 5s default is indefensible.** A warm load alone is 3.3s with *zero* inference performed, and the only reason such a call survives today is that it happens to finish inside the budget. There is no headroom for the inference itself.

**A cold load is 7× over budget.** The first caller cannot be made to wait inside any fixed timeout. Today it is simply cut off, and `AgentDb.search(mode: :vector)` reports the resulting exit to the caller as a dead process rather than a condition it can act on.

**Job retry cannot mean "still loading".** 15 seconds of retry budget against a 37-second cold path means the job is marked `failed` before the download could possibly finish. Because `count_pending_jobs/1` filters to `status IN ('pending','running')`, a `failed` job reads as "nothing outstanding", so `write(async: false)` returns `:ok` having accomplished nothing. A caller in sync mode is told embedding and summarization completed when the job died on its first attempt.

The load also still runs inside `handle_call`, so a load occupies the only inference process for its whole duration — `model_status/0`, a call that merely reads state, is unavailable for 3.3s warm and would be for ~37s cold.

## What Changes

- **Adopt a three-state result for model-dependent work.** `{:ok, result}`, `{:error, :model_loading}` when a load is in flight, and the existing classified failures (`:model_not_found`, `:download_failed`, `:model_load_failed`). A caller can now distinguish "not ready yet, ask again" from "this will never work".
- **A synchronous caller waits a short, configurable grace period and then gets `{:error, :model_loading}`.** A cached model becomes ready inside the grace period, so the common path stays transparent; a cold first-use returns promptly instead of hanging or being cut off.
- **Move the load off the `handle_call` path.** The load runs as work the GenServer supervises rather than inside it, so `model_status/0` and other callers stay responsive while a model is being fetched and loaded.
- **A background job that finds the model loading is re-queued without consuming a retry attempt.** Retry budget is reserved for failures that can succeed on retry, so a slow first download cannot exhaust it.
- **Sync mode reports outcomes honestly.** `write(async: false)` distinguishes completed, failed, and still-pending, and returns an error when the jobs it waited on failed.
- **Add configuration** for the grace period, and give the model-dependent GenServer calls an explicit timeout rather than relying on the 5s default.

Not in scope: eager loading, inference itself (blocked on `port-inference-to-bumblebee-serving`), a separate loader *process* (this keeps the load in the same process as inference, which is required because a loaded model cannot cross a process boundary cheaply), and the `model_cache_dir` / `put_default_config/0` behavior that silently overrides a pre-set cache directory.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `llm-summarization`: `LLM model management` — loading is lazy, so a request made while a model is loading SHALL be reported as loading rather than as a failure, and a caller SHALL be able to retry it. `Summarization idempotency and retry` — a job deferred because the model is loading SHALL NOT consume its retry budget.
- `vector-search`: `Embedding model management` — the same three-state contract for embeddings. `Vector similarity search` — a search issued while the embedding model is loading SHALL report that condition rather than failing as though the query were invalid.
- `context-store`: `Background job processing` — retry budget is not consumed by deferral. `Async write acknowledgement` — a caller that asked for synchronous work SHALL be told whether it completed, failed, or is still outstanding. `Configuration for models and async behavior` — the load grace period is configurable.
- `http-api`: `Model status and health endpoints` — model status SHALL remain answerable while a model is loading. `WebSocket gateway for all store operations` — a call deferred because a model is loading SHALL be distinguishable by the client from a call that failed outright.

## Impact

- **Code:** `lib/agent_db/ml/model_manager.ex` — `embed/1`, `summarize/2`, `handle_call/3`, `do_embed/2`, `do_summarize/3`, plus a load-status field in `ml/model_manager/state.ex`. `lib/agent_db/job_queue.ex` — a requeue that does not consume an attempt. `lib/agent_db/agent_db.ex` — `wait_for_jobs/4` and `count_pending_jobs/1` for honest sync mode.
- **Behavior:** callers that pattern-match `{:error, reason}` keep working, but `reason` can now be `:model_loading`, and a wildcard match that assumed "any error means the feature is unusable" will need revisiting. Sync-mode `write/3` can now return an error where it previously always returned `:ok`.
- **Config:** new `model_load_grace_ms`. No existing key changes meaning.
- **Tests:** the grace period, the requeue-without-attempt behavior, and sync-mode failure reporting are all testable without weights, using the loader seam `fix-model-loading` introduced. The end-to-end "cold load then search" path is not, for the same reasons recorded in `fix-model-loading` tasks 4.1/4.2.
- **Dependencies:** none added.
