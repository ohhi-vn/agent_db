# Tasks

## 1. Make the Load Path Testable

Nothing below can be verified until a test can reach the load path; `ensure_model_files/3` returns early under `Mix.env() == :test` and the whole capability has zero coverage.

- [x] 1.1 Make the load path reachable in the test environment: either condition the test short-circuit on the model file being absent rather than on `Mix.env()`, or expose the loader so a pre-populated cache directory can be exercised directly. Verify a test can now observe a successful load rather than only the not-found error
- [x] 1.2 Add a regression test asserting that loading a cached embedding model succeeds and produces an embedding. **This test must fail against the current code** — confirm it does before moving on, because a test that passes against the broken loader proves nothing
      - *Verified: reintroducing the double `load_model` call fails 3 of the new `BumblebeeLoader` tests. Note the first attempt at this proof FAILED to catch it — the seam was initially at the loader boundary, so a fake loader bypassed the very code that was broken. Seam moved to the library boundary (`BumblebeeLoader.load_model/3` takes the Bumblebee module) so the defect is reachable.*
- [x] 1.3 Add a test asserting a second embedding request does not reload the model, and that a failed load leaves no cached model behind so a later request retries
- [x] 1.4 Add a test asserting an interrupted download leaves no file at the model's cache path, and that a later request retries the download

## 2. Fix Model Loading

- [x] 2.1 In `load_embedding_model/1`, remove the second `Bumblebee.load_model/1` call and destructure the `{:ok, %{model:, spec:}}` the first call already returns. Verify 1.2 passes and that the `model_ref` retains the `serving` key that `generate_embeddings/3` depends on
- [x] 2.2 Apply the same fix to `load_llm_model/1`, keeping its `Bumblebee.Text.Generation` serving. Verify a cached summarization model loads and produces a summary
- [x] 2.3 Thread the configured backend into `load_model/2` in both loaders, replacing the discarded `_backend = config.exla_backend` bindings. Verify a configured backend is passed through rather than dropped, and confirm no `_`-prefixed discarded binding remains in the module

## 3. Make Failure Non-Destructive

- [x] 3.1 Replace `Req.get!/1` with `Req.get/2` plus a `case` on the response, so an HTTP error status is a handled value rather than a raise. Verify a non-200 response returns an error tuple
- [x] 3.2 Move `ensure_model_files/3` inside the `try` in both loaders so a transport failure is caught. Verify that with no network and no cached model, the request returns an error and the calling process is not terminated
- [x] 3.3 Write to a `.part` path and rename into place only after a `200`, removing the partial file on failure. Verify an interrupted download leaves no file at the final path
- [x] 3.4 Pass an explicit `receive_timeout` to the download. Verify it is set rather than relying on the 15s default, and that a slow host no longer blocks the inference process for an unbounded time
      - *Set to 30s as a module attribute. Still not configurable — Config has no timeout knobs, and adding one belongs to the deferred timeout-policy work.*
- [x] 3.5 Verify `ModelManager` survives each failure mode — offline, HTTP error, interrupted download, bad repository — and that a trivial `model_status` call still responds afterwards. This is the scenario proving an unavailable model does not disable the store
      - *Verified against a loopback HTTP server for each mode. Note: a truncated transfer is retried by Req with backoff and outlasts the 5s `GenServer.call` budget, so those assertions accept either an error tuple or a cut-off. That is the deferred timeout policy, not a defect here.*

## 4. End-to-End Verification

- [ ] 4.1 With a real cached model, write a document and confirm a row appears in `vec_nodes` and an `abstract` is generated rather than falling back to the first content line. This is the first time either has ever been observed; treat a failure here as a finding, not a flake
      - **PARTIAL, and the remainder is BLOCKED — not by this change.** The load itself is verified against real weights: a genuine WordPiece tokenizer loads (vocab 30522) and the model is retained across calls. Inference then fails with `Bumblebee.Text.TextEmbedding.tokenize/2 is undefined` — in the pinned Bumblebee 0.7.1 that module exports only `text_embedding/3`, which builds an `Nx.Serving` spec. The `tokenize/2` + `generate/3` pair this code calls does not exist in that version. Fixing it means rewriting `generate_embeddings/2` and `generate_summary/2` onto `Nx.Serving`, which is a separate change (filed as a follow-up) and also changes what `model_ref` carries. `vec_nodes` persistence is separately blocked by sqlite-vec being absent from this machine. So neither the `vec_nodes` row nor the generated `abstract` can be observed here.
- [ ] 4.2 Confirm vector search returns ranked results and hybrid search is no longer identical to keyword-only
      - **BLOCKED by 4.1.** Both require embeddings to be produced, which requires the `Nx.Serving` rewrite. What is confirmed is only the negative: with no model, `mode: :vector` and `mode: :hybrid` now return `{:error, {:model_not_found, _}}` instead of crashing the caller.
- [x] 4.3 Confirm the four `specs/` scenarios requiring an observable successful load are each backed by a named test or a recorded manual run, and that none is satisfied by a check that would also pass against the broken loader
      - *Audit of every scenario this change adds:*
      - *Cached model loads successfully* -> `BumblebeeLoaderTest calls the library once, with a repository` + `ModelManagerLoadingTest produces an embedding and reports the model as loaded` + `does not reload the model on a second request`
      - *A failed load is reported, not silently substituted* -> `a loader that raises is reported, not propagated`, `a loader that exits is reported, not propagated`
      - *Configured backend is applied* (vector-search, llm-summarization, context-store) -> `passes the configured backend to the loader`, `omits the backend option for :cpu rather than passing the atom`, `defaults to the Nx backend when no backend is configured`, `an accelerator without a configured EXLA client does not reach the library`. One code path serves all three capabilities, so the llm/context-store variants are the same tests.
      - *Cached summarization model loads successfully* -> `loads and runs the summarization model`
      - *Interrupted download does not poison the cache* (vector-search, llm-summarization) -> `a truncated response leaves nothing at the model path`, `a later request retries rather than trusting a partial file`, `a successful download writes the body to the model path and leaves no partial file`. `download_model/4` is one function used by both model roles, so the llm variant is the same test.
      - *Offline with uncached models reports an error* / *Unavailable model does not disable the store* -> `reports an error and does not terminate the caller`, `leaves later requests serviceable and retries the load`, `survives every download failure mode and stays responsive`
      - *Unservable call returns an error, not a crash* -> `a search that needs an unavailable model reports an error, not a crash`, `a hybrid search that needs an unavailable model reports an error, not a crash`. The hybrid test **found a real in-scope bug**: `hybrid_search` hard-matched `{:ok, _} = Task.await(...)` and raised MatchError. Fixed, along with the dead `_scope_prefix` binding in the same function.
      - *Only the load-success scenarios are backed by a manual run; 4.1/4.2 remain open for the reason below.*
- [x] 4.4 Run `mix compile` and `mix test`; confirm no new warnings and no regressions against the 72-test baseline
      - *94 passed, 0 failed (baseline 72). Zero new compiler warnings, verified by diffing the warning set against a stashed baseline. `--warnings-as-errors` still fails on the same 52 pre-existing warnings.*
- [x] 4.5 Record in release notes that `AGENT_DB_EXLA_BACKEND` is now functional, that a host misconfigured for CUDA/ROCm will now fail at load rather than silently falling back, and that already-truncated `model.safetensors` files must be deleted manually
      - *The project has no CHANGELOG or release-notes file, so rather than introduce one for a 0.1.0 project with no release history, the notes were added to README under "Models -> Model cache notes", where the model configuration they describe is already documented.*
