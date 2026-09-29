# Tasks

## 1. Make the in-flight load reference per-role

- [x] 1.1 Change `loading_ref` in `lib/agent_db/ml/model_manager/state.ex` from `reference() | nil` to a map keyed by `:embedding` and `:llm`, and change the struct default from `nil` to `%{}` — verify `mix compile` succeeds
- [x] 1.2 In `start_load/3` in `lib/agent_db/ml/model_manager.ex`, write the reference under its own role with `Map.put(state.loading_ref, role, ref)` instead of overwriting the whole field — verify `mix compile` succeeds
- [x] 1.3 In `handle_cast({:load_result, ...})`, match the incoming reference against `state.loading_ref[role]` instead of `state.loading_ref` — verify `mix compile` succeeds
- [x] 1.4 Confirm a manager that has just started still rejects a leftover result from a previous instance: an empty `loading_ref` map yields `nil`, which matches no reference, so the result is dropped — verify this by reading the guard, and cover it with a test if 2.2 does not already exercise it

## 2. Cover the two roles loading concurrently

- [x] 2.1 Add a test that uses a loader slow enough that both roles are still loading when the second call arrives, and cache weights for both the embedding and summarization model ids so neither load short-circuits
- [x] 2.2 In that test, issue an embedding request and a summary request while both loads are in flight, then require that BOTH roles settle at ready rather than one remaining at loading — verify the test fails against the current code and passes after 1.1 through 1.3
- [x] 2.3 In the same test, once both roles are ready, require an embedding request and a summary request to both proceed rather than continuing to report the model as loading — verify the test passes

## 3. Verify no regression

- [x] 3.1 Run the full `mix test` suite and verify it passes, paying attention to `test/agent_db/ml/model_manager_loading_test.exs`, `test/agent_db/ml/model_load_state_test.exs`, and `test/agent_db/ml/job_deferral_test.exs` — verify no existing load-state assertion moved
- [x] 3.2 Confirm `model_status/0` and the `{:load_status, role}` reply shape are unchanged, since callers and the web model-status endpoint read them — verify by inspection that neither the reply construction nor `build_model_status/1` was touched
