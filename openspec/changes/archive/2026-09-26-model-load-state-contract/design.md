# Design

## Context

See proposal.md for motivation and the spec deltas for required behavior. The measurements below are the constraint that shapes everything; they were taken on this machine against `all-MiniLM-L6-v2` after `fix-model-loading` landed.

**Loading is lazy, and it is slow enough to matter.**

| | |
|---|---|
| cold load — download + load | 36,929ms |
| warm load — cached weights | 3,286–3,649ms |
| default `GenServer.call` budget | 5,000ms |
| `model_status/0` during a warm load | 3,663ms — unavailable |
| download `receive_timeout` | 30,000ms |
| job retry budget | ~15s wall clock (5 attempts: 1+2+4+8) |

A warm load is 3.3s *before any inference runs*, against a 5s default. There is no headroom. A cold load is 7× the budget.

**The warm number is inflated by a bug that is not this change's to fix.** `generate_embeddings/2` calls `Bumblebee.Text.TextEmbedding.tokenize/2`, which does not exist in the pinned 0.7.1, so it raises and the GenServer dies *after* `ensure_embedding_model/1` returned new state. That state is never stored, so every call reloads. A working inference path would make warm calls faster — the 3.3s is a load-only figure and a real warm call is that plus inference.

**The load currently runs inside `handle_call/3`.** `do_embed/2` calls `ensure_embedding_model/1` synchronously, so a load occupies the only inference process for its full duration. That is what makes `model_status/0` unavailable, and it is why a cold first-use blocks the entire ML subsystem for ~37s.

**Job retry cannot express "still loading".** `dequeue/1` advances `attempts` when it claims a row, and `fail/3` re-schedules while `attempts < max_attempts`. Fifteen seconds of budget against a 37-second cold path means a job is marked `failed` before the download can finish.

**`write(async: false)` cannot report failure.** `count_pending_jobs/1` filters `status IN ('pending','running')`, and `wait_for_jobs/4` returns `:ok` when the count reaches zero. A `failed` job therefore reads as "nothing outstanding", so sync mode returns `:ok` after a job died on its first attempt. Three outcomes — completed, failed, still pending — collapse into one return value.

## Goals / Non-Goals

**Goals:**
- Give model-dependent work a three-state result so a caller can tell "not ready, ask again" from "this will not work".
- Make a cached model transparent to the caller, and a cold model prompt rather than a hang or a cut-off.
- Stop a load from occupying the only inference process.
- Reserve the retry budget for retryable failures.
- Make sync mode report what actually happened.
- Make the wait configurable, and never unbounded.

**Non-Goals:**
- No eager loading, and no change to the lazy/eager decision.
- No inference work. `port-inference-to-bumblebee-serving` owns that, and until it lands a produced embedding cannot be observed end to end.
- No separate loader *process*. The load stays in the same process as inference, because a loaded model is an Nx/EXLA structure that cannot cross a process boundary cheaply, and moving it would trade a scheduling problem for a data-movement one.
- No change to `model_cache_dir`, and no fix for `put_default_config/0` overwriting it at boot.
- No schema migration.

## Decisions

### Three states, with `:model_loading` as its own value

`{:ok, result}` · `{:error, :model_loading}` · the existing classified failures.

*Why:* the current pair conflates "not yet" with "never". A caller cannot write correct retry logic against `{:error, :model_not_found}`, because that value is equally correct for a host that will never have the model. A distinct atom is the smallest thing that makes the retry decision expressible, and it costs one new clause at each call site rather than a new type.

*Alternative considered:* a `{:error, {:not_ready, retry_after_ms}}` tuple. Rejected — the delay is not something the caller can act on precisely, and it would tempt callers to trust a number that is only a guess.

### The load leaves `handle_call/3`; the client absorbs the wait

`handle_call({:embed, texts}, ...)` starts the load as supervised work if it is not already running, and returns `{:error, :model_loading}` immediately. The wait lives in the client function: `embed/1` calls through, and on `:model_loading` polls readiness until a configurable deadline, then retries the call once before giving up.

*Why:* this is the only arrangement that both keeps the GenServer free and makes a cached model invisible to the caller. Doing the wait inside `handle_call` would re-create the wedge; making the caller poll unconditionally would force every caller to handle `:model_loading` even when the model is already warm, which is the common case.

*Alternative considered:* `GenServer.reply(from, result)` from the load's completion callback, with the client blocking on a long timeout. Rejected — it makes a single `embed/1` call hold for the whole cold path, and the HTTP layer would need a matching request timeout, so the fixed 5s problem returns one layer up.

*Consequence:* the grace period is a wall-clock bound on the caller, not a bound on the load. The load continues regardless, and a later caller finds the model ready. That is the intended shape, and it is why the deferred job in the queue below can simply be rescheduled.

### A deferred job is rescheduled without consuming an attempt

`JobQueue` gains a requeue that returns the row to `pending` with a future `scheduled_at` and gives back the attempt that `dequeue/1` advanced, so the deferral is attempt-neutral.

*Why:* the retry budget is calibrated for transient inference failures and is two orders of magnitude too small for a cold load. Attempt-neutral deferral is what lets a job survive a 37-second first download instead of being marked `failed` at 15.

*Alternative considered:* let the deferral consume attempts and simply raise `max_attempts`. Rejected — it converts a one-time cost into a permanent budget increase, and every real failure afterwards would then retry far more than intended.

*Alternative considered:* leave the job `running` and poll inside the worker. Rejected — a `running` row is invisible to `reset_running_jobs/0`, so a restart during a long load would strand it.

### Sync mode reports three outcomes, not one

`count_pending_jobs/1` stops treating `failed` as "nothing outstanding", and `wait_for_jobs/4` returns a distinct result for still-pending versus failed.

*Why:* the existing spec says `async_writes: false` blocks "until embedding and summarization complete". Today it blocks until the queue looks idle and then asserts success, which is how a failed job becomes a successful write. This is the requirement being made true rather than a new promise.

*Consequence:* `write(async: false)` can now return an error where it previously always returned `:ok`. That is the intended correction and it is caller-visible, which the proposal records.

### One configurable knob: `model_load_grace_ms`

*Why:* the measured spread is 3.3s warm against 37s cold, so no single default is right for both and the caller needs to be able to trade its own latency against the chance of a transparent first call. One knob, read at call time like the rest of `Config`.

*Alternative considered:* deriving the grace from measured load history. Rejected — it optimises the wrong thing, since the cold path is bounded by network speed the store does not control.

## Risks / Trade-offs

- **Polling for readiness costs a little latency and some wakeups** → The poll interval is short relative to a multi-second load, and the alternative is holding a GenServer call open. Accepted.
- **A caller that retries `:model_loading` in a tight loop can spin** → The worker path is protected because deferral is attempt-neutral and rescheduled; the synchronous path is bounded by the grace period. Documented rather than enforced, since adding a rate limit here would be speculative.
- **Sync mode returning an error may surprise callers who treat `:ok` as the only success** → Correct, and recorded in the proposal as a caller-visible change. It is the difference between reporting and hiding a failure.
- **The load now outlives the call that started it** → Intentional, and the reason a later caller finds the model ready. It does mean a load can be in progress with no caller waiting; that is what `model_status/0` now reports.
- **The 3.3s warm figure will drop once inference is fixed**, possibly making the default grace generous → Harmless: a generous grace only costs latency on a call that would otherwise be refused, and the knob is there if it matters.
- **End-to-end verification stays blocked** → The three-state contract, attempt-neutral deferral, and sync-mode reporting are all testable without weights, via the loader seam from `fix-model-loading`. Observing a real cold load followed by a successful search still needs `port-inference-to-bumblebee-serving` and sqlite-vec, so tasks will say so rather than implying full coverage.

## Migration Plan

No schema migration and no data migration. Deploy order is the normal one.

**Rollback:** revert the code. Nothing durable changes — the requeue is a runtime scheduling behaviour, and the load already survives a process restart by re-reading the cache.
