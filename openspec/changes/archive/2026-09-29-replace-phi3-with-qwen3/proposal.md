# Proposal

## Why

The configured summarization model, `microsoft/Phi-3-mini-4k-instruct`, is not supported by EMLXAxon. That package ships model rewrites for Llama and Qwen3 only, and a search of its source finds no Phi support at all. On a machine where EMLX is available, switching the backend would therefore leave the summarization model unaccelerated — the one workload EMLXAxon is built to speed up.

The `emlx-support` change already concedes this: its risk table lists "Phi-3-mini not supported by EMLXAxon" with the mitigation "fallback to EXLA". A silent fallback on the default configuration is not acceleration, so that change cannot deliver its stated purpose while Phi-3 is the default.

Swapping the default to a model EMLXAxon supports removes the conflict. This is deliberately its own change rather than part of `emlx-support`: the swap is a behavior change to summarization, it can be made and verified before any EMLX code exists, and it costs summarization quality on plain EXLA in the meantime.

## What Changes

- **Replace the default summarization model with Qwen3-0.6B.** The default in `AgentDb.Config.llm_model/0` and `AgentDb.Application.put_default_config/0`, plus the documented example in `config/example.exs`, moves from Phi-3-mini to `Qwen/Qwen3-0.6B`. The download URL default moves to a matching Q4_K_M GGUF.
- **Make the chat template configurable rather than hardcoded.** `format_prompt/1` embeds Phi-3's `<|user|>…<|end|>` markers as a string literal, with nothing linking it to the model it was written for. Bumblebee 0.8.0 exposes no chat-template API, so the template cannot be obtained from the library; it is per-model data that has to be supplied. A new `llm_chat_template` configuration key carries it, defaulting to Qwen3's ChatML markers.
- **Strip reasoning blocks from generated summaries.** Qwen3 is a hybrid reasoning model and emits a `<think>` block before its answer. The raw text currently reaches the caller and is stored as the document's abstract. Reasoning content is removed before the summary is returned.
- **Treat an empty result as a failure.** If stripping leaves nothing, the model spent its whole budget reasoning without answering. `abstract/1` and `overview/1` fall back to the first line and the first 280 characters when the stored value is `nil`, but an empty string is truthy in Elixir and silently defeats that fallback. An empty generation is therefore reported as an error, which leaves the stored value `nil` and preserves the existing fallback.
- **Report model size from configuration.** `build_model_status/1` hardcodes `params: "3.8B"`, and `http-api`'s model-status scenario asserts that literal. A new `llm_model_params` configuration key supplies the value, and the spec assertion stops restating a hand-written string.

Not in scope: the EMLX/EMLXAxon backend work itself (`emlx-support`), any inference rewrite (`port-inference-to-bumblebee-serving`), and the download path. The latter is a separate defect: `ensure_model_files/3` downloads a file that nothing reads, because `Bumblebee.load_model({:hf, id})` re-fetches from the HuggingFace Hub into its own cache. The URL default changes here only so it stops naming a model the store no longer uses.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `llm-summarization`: `LLM model management` — the configured model is no longer tied to a specific architecture; the chat template used for prompts becomes configuration rather than a hardcoded assumption; and generated summaries exclude the model's reasoning content, with an empty result reported as an error rather than stored.
- `http-api`: `Model status and health endpoints` — the reported model size reflects the configured model instead of a literal in the source.

## Impact

- **Code:** `lib/agent_db/config.ex` (`llm_model/0`, `llm_model_url/0`, plus new `llm_chat_template/0` and `llm_model_params/0`); `lib/agent_db/application.ex` (`put_default_config/0` defaults and the matching environment variables); `lib/agent_db/ml/model_manager.ex` (`format_prompt/1`, reasoning-stripping in `generate_summary/2`, empty-result handling, `build_model_status/1`); `config/example.exs`.
- **Behavior:** visible to anyone reading generated abstracts and overviews. Summaries lose the Phi-3 quality of a 3.8B model and gain Qwen3-0.6B's, and the model's reasoning is no longer mixed into the stored text. Both are the intended point of the change.
- **Tests:** `test/agent_db/ml/model_load_state_test.exs` and `test/agent_db/ml/model_manager_loading_test.exs` pin `@llm_id` to the Phi-3 id; they need the new default. Reasoning-stripping and the empty-result error need coverage, and the existing fake generation serving returns a fixed string, so it must be extended to produce controllable output.
- **Environment:** `AGENT_DB_LLM_MODEL`, `AGENT_DB_LLM_MODEL_URL`, and the new `AGENT_DB_LLM_CHAT_TEMPLATE` / `AGENT_DB_LLM_MODEL_PARAMS`.
- **Supply chain:** the Q4_K_M build is published by a third party rather than by Qwen, whose own repository ships q8_0. This is a deliberate trade of provenance for a 484 MB download against 805 MB, and it is recorded here so it is a decision rather than an accident.
- **Dependencies:** none added. The current uncommitted bump already provides Bumblebee 0.8.0 and Nx 1.0.0, which this change targets.
- **Risk:** this change does not by itself make summarization better. On plain EXLA it makes it a 0.6B model instead of 3.8B. Its value is that it unblocks `emlx-support`, which is where the acceleration is supposed to come from.
