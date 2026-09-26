# Proposal

## Why

Embedding and LLM summarization have never once succeeded. `load_embedding_model/1` and `load_llm_model/1` call `Bumblebee.load_model/1` twice — once with `{:hf, model_id}`, then again with the already-loaded map — and the second call raises `ArgumentError`, because Bumblebee only accepts `{:hf, id}` or `{:local, dir}` as a repository. That raise is swallowed by the surrounding `catch :error` and reported as `{:error, {:model_load_failed, %ArgumentError{}}}`, a plausible-looking error rather than a crash.

Every consequence is silent. `vec_nodes` is never populated, so vector search always returns nothing and hybrid search silently degrades to keyword-only. `abstract`/`overview` are never generated, so the deterministic fallbacks are indistinguishable from working summaries. Every background job exhausts its five retries and lands in `failed`, which `count_pending_jobs` excludes, so `write(async: false)` returns `:ok` having done nothing. Line coverage on this path is complete and the suite is green, because the code runs — it just always takes the same branch.

The `vector-search` and `llm-summarization` capabilities have therefore never described this system.

## What Changes

- **Fix the double `load_model` call.** Consume the `{:ok, %{model: model, spec: spec}}` that the first call already returns, instead of feeding it back in. This is a prerequisite for embeddings and summaries existing at all.
- **Make `exla_backend` real.** The configured backend is currently bound to `_backend` and discarded in both loaders, and `Bumblebee.load_model/2` already accepts a `:backend` option that is never passed. `AGENT_DB_EXLA_BACKEND` currently has no effect despite being documented in `README.md:84,110,173` and `config/example.exs:7-12`.
- **Stop the offline path from crashing the inference process.** `ensure_model_files` runs as the scrutinee of the `case` in both loaders, so it is evaluated *outside* the `try`. A `Req.get!` transport failure there escapes `handle_call`, kills the `ModelManager` GenServer, discards any loaded model state, and restarts into the same failure. Being offline is the condition the `Pure offline operation` requirement promises to support.
- **Bound the download.** `Req.get!/2` is called with no options, so Req's 15s default `receive_timeout` applies and is not configurable. A single slow download blocks the only inference process for its full duration.
- **Stop a partial download from poisoning the cache permanently.** `download_model/3` writes the response body straight to the final `model.safetensors` path, and `ensure_model_files/3` treats `File.exists?/1` as the only completeness check. A truncated file passes every subsequent boot, then fails at load, and is never retried — the only recovery is manual deletion.

Explicitly **not** in this change: eager vs lazy loading, timeout policy for inference, splitting a loader process out of `ModelManager`, the three-state `{:error, :model_loading}` contract, and `async: false` reporting failure honestly. All of those are unobservable until loading works, and are deferred to a follow-up change so this one lands with a real measurement behind it.

## Second blocker found during implementation

Loading was not the only thing broken. With the load fixed and a real model verified end to end, the next failure is immediate and independent: `generate_embeddings/2` calls `serving.tokenize/2` and `serving.generate/3` on `Bumblebee.Text.TextEmbedding`, but in the pinned Bumblebee 0.7.1 that module exports only `text_embedding/3`, which builds an `Nx.Serving` spec. The `tokenize/2` + `generate/3` pair this code expects does not exist in that version, so inference raises `UndefinedFunctionError` and terminates the `ModelManager`.

Rewriting inference onto the `Nx.Serving` API is a separate change with its own risk surface — it also changes what `model_ref` must carry. It is deliberately not absorbed here, and the two affected scenarios in the `vector-search` and `llm-summarization` deltas are worded to claim the load succeeding and the request reaching inference, not an embedding or summary being produced. **`vector-search` remains non-functional on this change; its remaining blocker is inference, not loading.** A follow-up change is filed for it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `vector-search`: `Vector embeddings generated for all documents` gains a scenario requiring a successful load to be observable at all; `Embedding model management` gains the requirement that a configured compute backend is actually applied to the loaded model.
- `llm-summarization`: `LLM model management` gains the same load-succeeds and backend-applied requirements for the generation model.
- `context-store`: `Pure offline operation` gains the scenario that being offline with uncached models returns an error rather than terminating the caller, and does not leave the store unable to serve later requests; `Configuration for models and async behavior` gains the requirement that a configured backend selection is applied rather than ignored.
- `http-api`: `WebSocket gateway for all store operations` gains the scenario that a store operation which cannot be served reports an error response instead of terminating the calling process.

## Impact

- **Code:** `lib/agent_db/ml/model_manager.ex` — `load_embedding_model/1`, `load_llm_model/1` (the double call, the discarded backend, the `try` boundary, the `Req.get!` options, the download destination).
- **Behavior:** the first successful embedding populates `vec_nodes` for the first time, so vector search and hybrid search stop being no-ops. `abstract`/`overview` may begin returning generated text where they previously always returned fallbacks — a visible change for callers who (reasonably) came to rely on the fallbacks being stable.
- **Config:** `exla_backend` / `AGENT_DB_EXLA_BACKEND` changes from inert to functional. A machine currently misconfigured for `:cuda` will, after this change, attempt CUDA and may fail at load instead of silently running on CPU. That is the correct behavior but it is a behavior change.
- **Tests:** nothing currently exercises model loading. `ensure_model_files/3` short-circuits under `Mix.env() == :test`, so the load path has no coverage at all. A regression test asserting a successful load is the only thing that would have caught this.
- **Data:** existing truncated `model.safetensors` files in local caches are *not* repaired by this change; they will keep failing until deleted. Worth calling out in release notes.
- **Dependencies:** none added.
