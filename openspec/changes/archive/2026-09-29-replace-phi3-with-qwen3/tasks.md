# Tasks

## 1. Configuration

- [x] 1.1 Change the `llm_model/0` and `llm_model_url/0` defaults in `lib/agent_db/config.ex` from Phi-3-mini to `Qwen/Qwen3-0.6B` and a matching Q4_K_M GGUF URL — verify `mix run -e "IO.inspect AgentDb.Config.llm_model()"` returns the new id
- [x] 1.2 Add `llm_chat_template/0` to `lib/agent_db/config.ex`, defaulting to a template with a `%{prompt}` placeholder wrapped in Qwen3's ChatML markers — verify it returns a string containing `%{prompt}` and the `<|im_start|>` markers
- [x] 1.3 Add `llm_model_params/0` to `lib/agent_db/config.ex`, defaulting to the new model's size — verify it returns a non-empty string
- [x] 1.4 Update `put_default_config/0` in `lib/agent_db/application.ex` so the model, URL, template, and params all have matching `AGENT_DB_LLM_*` environment variable fallbacks and no longer reference Phi-3-mini — verify a grep for `Phi` across `lib/` returns no hits
- [x] 1.5 Update `config/example.exs` to document the new model, URL, `AGENT_DB_LLM_CHAT_TEMPLATE`, and `AGENT_DB_LLM_MODEL_PARAMS` — verify the file still compiles under `mix compile`

## 2. Prompt format comes from configuration

- [x] 2.1 Include the configured chat template in the ref returned by `build_model_ref/3` in `lib/agent_db/ml/model_manager.ex`, so it is snapshotted at load alongside the tokenizer and serving — verify `mix compile` succeeds
- [x] 2.2 Change `format_prompt/1` to take the template from the model ref and substitute the user prompt into the `%{prompt}` placeholder, deleting the hardcoded Phi-3 literal — verify no `<|user|>` marker remains anywhere in `lib/`
- [x] 2.3 Update the `model_ref` type in both `lib/agent_db/ml/model_manager.ex` and `lib/agent_db/ml/model_manager/state.ex` to include the template field — verify `mix compile` succeeds with no dialyzer-style type warnings about the new key

## 3. Reasoning is stripped and an empty result is an error

- [x] 3.1 In `generate_summary/2`, remove the segment from a `<think>` opening marker through the matching `</think>` before returning the summary, leaving text with no marker unchanged apart from trimming — verify the existing summarization tests still pass
- [x] 3.2 When stripping leaves nothing, return an error tuple rather than an empty string, so the job fails and the stored value stays `nil` — verify `SummarizationWorker` routes it to `JobQueue.fail` and that `abstract/1` still returns the first-line fallback for such a document

## 4. Model status reports the configured size

- [x] 4.1 Change `build_model_status/1` in `lib/agent_db/ml/model_manager.ex` to read the parameter size from config instead of the `"3.8B"` literal — verify `model_status()` reports whatever `llm_model_params/0` is set to
- [x] 4.2 Confirm no `3.8B` literal remains in the source — verify a grep across `lib/` and `test/` returns no hits

## 5. Tests

- [x] 5.1 Make the fake generation serving in `test/support/ml_fakes.ex` return configurable text instead of the fixed `"generated summary"`, defaulting to that string so existing tests are unaffected — verify the existing ml tests still pass before adding new ones
- [x] 5.2 Update `@llm_id` in `test/agent_db/ml/model_load_state_test.exs` and `test/agent_db/ml/model_manager_loading_test.exs` to the new default model id — verify those files compile and pass
- [x] 5.3 Add a test that a summary returned as reasoning-then-answer contains only the answer, and that the reasoning text is absent from the stored abstract — verify the test fails before 3.1 and passes after
- [x] 5.4 Add a test that a generation whose entire output is reasoning reports an error and stores nothing, leaving the first-line fallback in effect — verify the test fails before 3.2 and passes after
- [x] 5.5 Add a test that the prompt reaching the model is wrapped in the configured template rather than a hardcoded format, by overriding the template through the manager's config and asserting the formatted text — verify the test fails before 2.2 and passes after
- [x] 5.6 Add a test that `model_status()` reports the configured parameter size, including when it differs from the default — verify the test fails before 4.1 and passes after

## 6. Verify no regression

- [x] 6.1 Run the full `mix test` suite and verify it passes — verify no test that previously passed now fails
- [x] 6.2 Confirm `ensure_model_files/3` is unchanged, since the download path is a known separate defect and is deliberately out of scope — verify by inspection that the only change to it is the URL default in 1.1
- [x] 6.3 Run `openspec validate replace-phi3-with-qwen3 --strict` and verify the change is still valid — verify no deltas were lost
