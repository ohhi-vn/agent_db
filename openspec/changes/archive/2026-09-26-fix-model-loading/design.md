# Design

## Context

See proposal.md for motivation and the spec deltas for required behavior. Constraints below are current-state facts that shaped the approach, all verified against the pinned dependency versions in `deps/`.

**Bumblebee's two-phase load is already complete in one call.** `Bumblebee.load_model/2` returns `{:ok, %{model: model, params: params, spec: spec}}` (`deps/bumblebee/lib/bumblebee.ex:637`) — the model is already loaded into memory. The second call in `load_embedding_model/1` is not a second phase; it is a mistake. `normalize_repository!/1` (`bumblebee.ex:1358-1375`) accepts only `{:hf, id}`, `{:hf, id, opts}`, and `{:local, dir}`, and raises `ArgumentError` on anything else, so passing the returned map always raises.

**The `:backend` option already exists and is forwarded.** `load_model/2` declares `:backend` in its `Keyword.validate!` (`:629`) and forwards it to the params loader (`:677`), where it reaches the tensor allocation. Wiring `exla_backend` into that argument needs no new dependency and no new abstraction.

**`Req.get!/2` raises on transport failure, and the raise is outside the `try`.** `ensure_model_files/3` is the scrutinee of the `case` in both loaders, so it is evaluated before the `:ok ->` branch that contains the `try`. A `Req.get!` transport error therefore escapes `load_embedding_model/1`, escapes `handle_call/3`, and terminates the `ModelManager` GenServer. Req's `receive_timeout` defaults to 15,000ms (`deps/req/lib/req.ex:445`) and is not configured here.

**`Req.get!/2` and `File.write!/2` give no atomicity.** The response body is written straight to the model's final `model.safetensors` path, and `ensure_model_files/3` uses `File.exists?/1` as its only completeness test.

**`ensure_model_files/3` short-circuits under `Mix.env() == :test`**, returning `{:error, {:model_not_found, path}}` before any download. So no test can reach the load path, which is why the double-call defect is invisible to the suite.

## Goals / Non-Goals

**Goals:**
- Make a cached model load successfully, and make that success observable by a test.
- Make a configured backend take effect.
- Ensure every failure mode — offline, interrupted download, bad repository — returns an error tuple and leaves the `ModelManager` alive with its state intact.
- Make the on-disk cache trustworthy: a file at the model's path means a completed download.
- Delete the two discarded bindings that hid all of this.

**Non-Goals:**
- No change to lazy vs eager loading. `Embedding model management` already says loading "SHALL be lazy (on first embedding request) or eager (at startup, configurable)"; this change preserves whichever is in place and does not add the config knob that requirement implies but the code lacks. That gap is real and belongs to the follow-up.
- No inference timeout policy, no `{:error, :model_loading}` tri-state, no loader/supervisor split. All unobservable until loading succeeds.
- No change to the job queue, retry budget, or `async: false` semantics.
- No repair of already-poisoned local caches.
- No new dependency.

## Decisions

### Consume the first `load_model` result instead of calling it twice

Destructure the map the first call already returns and pass `:backend` on that same call.

```elixir
# current -- the second call always raises
{:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})
{:ok, model_info} = Bumblebee.load_model({:hf, model_id})
model = Bumblebee.load_model(model_info)

# one call; backend is a real argument
{:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})
{:ok, %{model: model, spec: spec}} = Bumblebee.load_model({:hf, model_id}, backend: backend)
```

*Why:* the fix and the backend wiring are the same edit, because both land on the one call that should have existed all along. `model_ref` then carries `tokenizer`, `model`, `spec`, and `serving` — `serving` is derived from `spec` via `Bumblebee.Text.TextEmbedding` or `.Text.Generation`, and `generate_embeddings/3` and `generate_summary/3` reach for `model_ref.serving`, so the struct must keep that key.

*Alternative considered:* keep two calls but pass `{:local, dir}` the second time. Rejected — it re-reads and re-converts weights to produce a model that already exists in memory, paying the full load cost twice per request for no benefit.

### Widen the `try` to cover model-file acquisition, and make the download fallible in a controlled way

`ensure_model_files/3` moves inside the `try`, so a `Req` transport failure is caught and returned as an error tuple rather than terminating the GenServer. The bang form is replaced with the non-bang `Req.get/2` plus a `case` on the response, so an HTTP error status is a handled value rather than a raise.

*Why:* `Pure offline operation` promises the store functions without network once models are cached, and the `http-api` delta requires that an unservable call returns an error rather than terminating the caller. Offline is not an exceptional case here — it is a documented operating mode — so it must not be the thing that kills the inference process.

*Consequence accepted:* a caller still blocks for up to the download timeout before receiving that error. Removing the block is the follow-up change's job. This change makes the outcome an error rather than a dead process, which is the part that is unambiguously wrong today.

### Download to a temporary path, then rename into place

`download_model/3` writes to `<model_file>.part` and renames on success, removing the partial file on failure. The body is streamed via `Req.get/2` with an explicit `receive_timeout` and written with `File.write!/2` only after a `200`.

*Why:* rename within a directory is atomic on POSIX, so a file at `model.safetensors` becomes proof of a completed download. That converts `File.exists?/1` from a guess into a valid completeness check, and makes the truncated-file scenario in both deltas unreachable rather than merely unlikely. It also means a killed process leaves at most a `.part` file, which the next attempt overwrites.

*Alternative considered:* verify size or checksum against the remote before renaming. Rejected — the server does not reliably expose a content length for these artifacts, and a checksum would be a second source of truth to keep in sync with HuggingFace. Rename is sufficient and needs no metadata.

*Cost noted:* this roughly doubles peak disk usage during a download, since both the partial and final file may briefly exist. For a multi-hundred-megabyte model that is acceptable next to the failure it removes.

### The backend value stops being discarded

Replace `_backend = config.exla_backend` in both loaders with a real argument threaded into `load_model/2`. No new configuration is introduced; the existing `Config.exla_backend/0` and `AGENT_DB_EXLA_BACKEND` become functional.

*Why:* this is what the `context-store` and `vector-search` deltas now require, and it is a precondition for `emlx-support`, whose entire premise is selecting a backend. Fixing it here means that change inherits a working seam instead of having to repair one.

*Behavior change flagged in the proposal:* a machine whose `AGENT_DB_EXLA_BACKEND` says `:cuda` on a host without CUDA will now fail at load rather than silently running on CPU. That is the requirement working, but it will look like a regression to anyone who set the variable and saw no effect for months. It belongs in release notes.

### A load failure does not poison subsequent requests

`state.embedding_model` is only assigned on success, and a failure leaves it `nil` so the next request retries. This is already the shape of `ensure_embedding_model/1`; the change is that a failure now actually happens only for real reasons instead of unconditionally, so the retry path is exercised for the first time.

*Why:* the `context-store` delta requires that an unavailable model not leave the store permanently unable to serve later requests. Retaining the previous behavior here is what makes that scenario true.

### Make success observable before anything else lands

A regression test exercises the load path against a cached model and asserts a successful load and embedding, and a second asserting the model is not reloaded. `ensure_model_files/3`'s `Mix.env() == :test` short-circuit is what made this unreachable, so the test must be able to run in the test environment — either by testing the loader against a pre-populated cache path, or by making the short-circuit conditional on the file being absent rather than on the environment.

*Why:* every defect in this change is invisible to line coverage because the lines run and always take the same branch. The only thing that would have caught any of them is an assertion that the success path is reachable. This is the one item in the change that protects the next four.

*Alternative considered:* rely on a manual verification run. Rejected — the last several defects in this codebase were all found by reading, not by running, and nothing keeps a manual check honest across time.

## Risks / Trade-offs

- **Tests will need real model weights, or a stubbed load boundary** → The double-call fix is inside a function that reaches `Bumblebee` and `Req` directly, so a test either downloads a model or the load step is made injectable. Injecting a seam is more code; downloading in a unit test is slow and network-dependent. Worth resolving during implementation — the spec scenarios need to be satisfiable without a multi-hundred-megabyte download, or they will be written as manual checks and quietly skipped.
- **A host misconfigured for `:cuda` will start failing** → Inherent to making the setting real, and called out in the proposal. A follow-up could validate the backend at boot and fall back with a warning, but that is new behavior, not a fix.
- **The download timeout remains a hardcoded or newly-chosen constant** → Making `receive_timeout` explicit is an improvement over an invisible 15s default, but the value is still not configurable, and `Config` has no timeout knobs. Deliberately not adding one here to keep the change to the loading defect; the follow-up owns timeout policy.
- **Atomic rename changes the cache layout's failure modes** → Any tooling that assumed a partially-written file might exist will no longer see one. Nothing in this repo does.
- **Peak disk usage during download roughly doubles** → Accepted; see the decision above.
- **Already-poisoned caches are not repaired** → A user with a truncated `model.safetensors` from before this change still fails until they delete the file, because the existence check cannot retroactively tell a truncated file from a good one. The atomic write only prevents new occurrences. This is a documentation item, not a code path.

## Migration Plan

No schema migration and no data migration. Deploy order is the normal one.

**Rollback:** revert the code. The only durable side effect is the on-disk model cache, which this change may populate for the first time; a revert leaves a valid cached model that the old code will still fail to load, so rollback does not restore prior behavior for anyone whose cache got populated. Worth stating plainly: this change cannot be cleanly rolled back for a first-time user, only for one already broken.

**Verification before considering this done:** a run against a real cached model showing a populated `vec_nodes` row and a non-fallback `abstract`, plus a run with no network and no cache confirming an error return and a surviving `ModelManager`.
