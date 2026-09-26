# Tasks

## 1. Three-State Result

- [x] 1.1 Add a load-status field to `ModelManager` state (`idle` | `loading` | `ready` | `failed`) and expose it through `model_status/0`, so "loading" is distinguishable from "not loaded". Verify `model_status/0` reports `loading` while a load is in flight
- [x] 1.2 Return `{:error, :model_loading}` from `embed/1` and `summarize/2` when a load is already in progress. Verify the value is `:model_loading` specifically, not a generic error
- [x] 1.3 Add `Config.model_load_grace_ms/0`, read at call time, defaulting to a value above the measured 3,649ms warm load. Verify the default covers a warm load and that overriding it changes how long a caller is held
      - *Default 10,000ms. Verified: a cached model completes inside a 5s grace with no retry visible to the caller, and a 50ms grace against a slow loader reports `:model_loading`.*

## 2. The Load Leaves handle_call

- [x] 2.1 Move the load out of `handle_call/3` so `do_embed/2` and `do_summarize/3` start it as supervised work and return `{:error, :model_loading}` immediately. Verify `model_status/0` is answered promptly while a load runs — this is the 3,663ms wedge, and the scenario is "The store stays responsive while a model loads"
      - *`do_embed/2` and `do_summarize/3` are gone, replaced by `ensure_model/2` plus `run_inference/3`. Verified: a state read answers in under 1s while a load is in flight, against a measured 3,663ms before.*
      - *Also added a generation guard on the load result. The load casts back by registered name, so a result from a terminated manager could land in its replacement and overwrite newer state. `loading_ref` is a `make_ref/0` — a counter was tried first and rejected, because it restarts at zero per manager, so a leftover load and a fresh one both present ref 1.*
- [x] 2.2 Make the client absorb the wait: on `:model_loading`, poll readiness until the grace deadline, then retry the call once before returning `:model_loading`. Verify a cached model completes inside the grace period with no retry visible to the caller (scenario "A cached model does not force the caller to retry")
- [x] 2.3 Ensure only one load runs per model role regardless of concurrent callers. Verify N concurrent first calls produce one download and one load, and all but one report `:model_loading`
- [x] 2.4 Confirm a load that outlives its starting call is still adopted by a later caller, and that a failed load leaves the status `failed` rather than stuck in `loading`
      - *Also fixed a flaw found while implementing 1.2: a load that FAILED during the grace wait was being reported as `:model_loading`, which would tell a caller to retry something that keeps failing. A wait now resolves to `:ready | {:failed, reason} | :timeout` and a failure is surfaced as itself.*

## 3. Retry Budget Is Not Spent Waiting

- [x] 3.1 Add `JobQueue` requeue that returns a row to `pending` with a future `scheduled_at` and gives back the attempt `dequeue/1` advanced. Verify the attempt count is unchanged across a requeue
      - *`requeue/3` (conn-taking, runs inside a caller's transaction) plus `defer/2` for the worker path. 25 consecutive deferrals leave the job at attempts 0 and still claimable.*
- [x] 3.2 Have both workers requeue with a delay when the model reports `:model_loading`, instead of calling `fail/2`. Verify a worker deferred many times still shows attempts below `max_attempts` and is never marked `failed` (scenario "Deferring for an unloaded model does not consume the retry budget")
- [x] 3.3 Verify a deferred job is reported as a distinct state from both a completed and a failed one, and that a restart during a long deferral leaves the job recoverable

## 4. Sync Mode Reports Honestly

- [x] 4.1 Stop `count_pending_jobs/1` treating `failed` jobs as nothing-outstanding. Verify a failed job is still counted as unresolved
- [x] 4.2 Make `wait_for_jobs/4` distinguish completed, failed, and still-pending, and have `write(async: false)` return accordingly. Verify a failed background job makes `write/3` return an error rather than `:ok` (scenario "Synchronous write reports failure rather than success")
      - *Added a `:sync_timeout_ms` write option so the pending case is testable without a 30s test; documented on `write/3`.*
      - *Replaced the triple-identical `payload LIKE ?1 OR ?2 OR ?3` with `json_extract(payload, '$.uri') = ?1`, matching on the actual field rather than the raw JSON text.*
- [x] 4.3 Verify still-pending work at the deadline reports outstanding rather than success, and that a completed job still returns `:ok`

## 5. Surface the Contract

- [x] 5.1 Verify `AgentDb.search(mode: :vector)` and `mode: :hybrid` propagate `:model_loading` unchanged, and add these to the existing unservable-search tests so the two states are distinguished
      - *`vector_search/2` and `hybrid_search/2` pass the error through unchanged, so `:model_loading` reaches the caller as-is. The distinction is carried by `ModelManager` returning the atom rather than by any new type.*
- [x] 5.2 Verify the WebSocket channel forwards `:model_loading` in a form a client can tell apart from a hard failure, and that the connection survives
      - *No harness was needed: `handle_in/3` is a plain function returning `{:reply, payload, socket}`, so it is called directly with a bare `%Phoenix.Socket{}`.*
      - *This surfaced a THIRD pre-existing defect, and a serious one: `v1.write`, `v1.search` and `v1.commit_session` passed the raw JSON string-keyed map straight into `AgentDb`, whose `Keyword.get/2,3` raises `FunctionClauseError` on a map. Every one of those three calls took the channel process down before reaching the store — so remote write, search and commit have never worked, and the existing `http-api` scenario "Remote search" has never held. Fixed by normalizing options at the channel boundary, with each option set listed explicitly so an unrecognised key is ignored rather than mistyped.*
- [x] 5.3 Record in the README model notes that a model-dependent call can now report that it is loading and is safe to retry
      - *Added to the existing "Models -> Model cache notes" section alongside the fix-model-loading notes, including `model_load_grace_ms` and the `model_status/0` states.*

## 6. Verification

- [x] 6.1 Run `mix compile` and `mix test`; confirm no new warnings against the current baseline and no regressions against 96 tests
      - *113 passed, 0 failed, up from 96. Zero new compiler warnings, verified by diffing the warning set against a stashed baseline. Ran the full suite 8 consecutive times to confirm determinism: two flaky tests were found and fixed rather than retried.*
- [x] 6.2 Re-read each spec scenario and confirm it is backed by a named test. Any scenario that cannot be tested without real weights or sqlite-vec must say so explicitly rather than be marked done
      - *Every scenario added by this change is backed by a named test, across `model_load_state_test.exs`, `job_deferral_test.exs`, `agent_db_test.exs` and `channel_error_test.exs`. No scenario in this change's deltas requires real weights or sqlite-vec — they are all about the contract, not about a produced embedding.*
- [x] 6.3 Record explicitly that the end-to-end "cold load, then successful search" path is still unobservable, and why — `port-inference-to-bumblebee-serving` for inference, and sqlite-vec's absence for `vec_nodes`
      - *Confirmed still unobservable, and now for three separate reasons: inference raises `UndefinedFunctionError` (owned by `port-inference-to-bumblebee-serving`); `vec_nodes` cannot be created without sqlite-vec, which has no package in `mix.lock`; and the WebSocket layer is only exercised here at the `handle_in/3` boundary, with no live connection test.*
