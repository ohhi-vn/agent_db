# Proposal

## Why

With model loading fixed (`fix-model-loading`), a real `all-MiniLM-L6-v2` now loads — a genuine WordPiece tokenizer, vocab 30522 — and the very next step fails. `generate_embeddings/2` calls `serving.tokenize/2` and `serving.generate/3` on `Bumblebee.Text.TextEmbedding`, but in the pinned Bumblebee 0.7.1 that module exports exactly one function:

```elixir
def text_embedding(model_info, tokenizer, opts \\ [])
```

That builds an `Nx.Serving` spec to be run through `Nx.Serving.run/3`. There is no `tokenize/2` and no `generate/3`. The call raises `UndefinedFunctionError`, which escapes `do_embed/2` and terminates the `ModelManager` — so vector search, hybrid search, and LLM summarization all still fail, now one layer further out than when this was first found.

This is a version-drift defect: the inference code was written against an older Bumblebee serving shape and never revisited when the dependency moved to `~> 0.6` / 0.7.x. `mix.exs` pins `{:bumblebee, "~> 0.6"}`, and 0.7.1 is what is installed.

## What Changes

- **Rewrite `generate_embeddings/2` and `generate_summary/2` onto the `Nx.Serving` API.** Build the serving once at load time via `Bumblebee.Text.TextEmbedding.text_embedding/3` and `Bumblebee.Text.Generation.text_generation/3`, hold it in `model_ref`, and run it per request with `Nx.Serving.run/3`.
- **Change what `model_ref` carries.** Today it holds a `serving` module plus a raw model, because that is what the two-call shape needed. It will hold a ready-to-run serving instead. `model_ref` is internal, but `model_status/0` and both workers reach into it, so the shape change has to be traced through.
- **Preserve the pooling and normalization behaviour.** `generate_embeddings/2` currently pools with `Nx.mean(axes: [1])` and L2-normalizes each vector. The rewrite must keep both, or embeddings stop being comparable to each other and to anything already stored in `vec_nodes`.
- **Keep inference failures non-fatal.** The `UndefinedFunctionError` currently kills the `ModelManager`. Whatever the new shape does, a failed inference must return an error tuple and leave the loaded model reusable, consistent with the containment `fix-model-loading` added for load failures.

Not in scope: model loading and download (already fixed), lazy-vs-eager selection, inference timeout policy, splitting a loader process out of `ModelManager`, and any `model_cache_dir` / `put_default_config/0` behavior. Those belong to the other deferred work.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `vector-search`: `Vector similarity search` — the store SHALL return ranked results with a similarity score per result, and SHALL report an error rather than terminating the caller when inference cannot run. `Hybrid search (keyword + vector)` — the vector leg SHALL contribute to fusion when embeddings are available.
- `llm-summarization`: `Automatic L0 abstract generation` and `Automatic L1 overview generation` — the store SHALL produce generated summaries from the locally loaded model, and SHALL report an error rather than terminating the caller when inference cannot run.

## Impact

- **Code:** `lib/agent_db/ml/model_manager.ex` — `generate_embeddings/2`, `generate_summary/2`, `build_model_ref/3` (build the serving), and the `model_ref` type in both `model_manager.ex` and `ml/model_manager/state.ex`. `lib/agent_db/ml/bumblebee_loader.ex` — `serving/1` currently returns a module; it will need to return or help build a serving instead.
- **Behavior:** this is the change that makes `vector-search` and `llm-summarization` real for the first time. `abstract`/`overview` will start returning generated text where callers currently receive the deterministic first-line and 280-character fallbacks, and `vec_nodes` will start filling. Both are visible changes to anyone who came to rely on the fallbacks.
- **Correctness risk:** the 384-dimension and consistency guarantees in `Vector embeddings generated for all documents` are testable for the first time here. Pooling or normalization drift would be invisible until results are compared against each other, so the existing spec's "consistent embeddings for identical content" scenario needs a real assertion.
- **Tests:** no test can currently assert a produced embedding or summary. `ensure_model_files/3` short-circuits under `Mix.env() == :test` and the model cache is empty in CI, so this needs either a small local model fixture or an injectable serving, on top of the loader seam `fix-model-loading` introduced.
- **Dependencies:** none added. Bumblebee and EXLA are already present.
- **Blocked elsewhere:** verifying that a row actually lands in `vec_nodes` also needs sqlite-vec, which is absent from this machine and has no package in `mix.lock`. That is a separate gap and is not fixed here.
