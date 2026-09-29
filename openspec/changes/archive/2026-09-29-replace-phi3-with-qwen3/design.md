# Design

## Context

See proposal.md for motivation. What constrains the approach:

- **Bumblebee 0.8.0 has no chat-template API.** `Bumblebee.Tokenizer` exposes only `decode/2`, `token_to_id/2`, `id_to_token/2`, `special_token/2`, `special_token_id/2`, and `all_special_tokens/1`. Grepping `chat_template` and `apply_chat_template` across `deps/bumblebee/lib/` and `deps/tokenizers/` returns one hit: a doc comment in `smollm3.ex:105` linking to the model's `chat_template.jinja` on HuggingFace. The only mention of chat formatting in the entire library is a pointer telling you it is your job. The prompt format is therefore data the store must supply; it cannot be obtained from the loaded model.
- **The current `format_prompt/1` has no link to its model.** It is a private function whose body is a Phi-3 string literal, with nothing in its type, its name, or its tests tying it to `llm_model`. That is why a version bump and a year of model changes passed without anyone noticing it was stale.
- **`""` is truthy in Elixir.** `agent_db.ex:867-868` reads `node.abstract || first_line(node.content)` and `node.overview || first_chars(node.content)`. Only `nil` and `false` fall through. An empty string stored as a summary permanently disables that fallback for the document.
- **`ensure_model_files/3` writes a file nothing reads.** It downloads `llm_model_url` to `<cache>/<id>/model.safetensors`, but `build_model_ref/3` calls `Bumblebee.load_model({:hf, id})`, which re-fetches through `HuggingFace.Hub.cached_download` into Bumblebee's own cache. The local tree is a marker, not a source. That is also why the current URL names a `.gguf` file at a `.safetensors` path without anything noticing.
- **Config is snapshotted into `state.config` at `init/1`,** and tests swap it with `:sys.replace_state`. Anything read at inference time must come through that map, not by calling `Config` directly, or the existing test seam stops working.

## Goals / Non-Goals

**Goals:**
- Make the summarization model configurable without any other code change needing to follow it.
- Keep generated summaries free of the model's intermediate reasoning.
- Preserve the existing read-time fallbacks when generation produces nothing usable.
- Stop reporting a hardcoded parameter size that describes a model the store may not be running.

**Non-Goals:**
- Rendering a model's `chat_template.jinja`. Qwen3's real template is a Jinja file with generation-mode branching; implementing a Jinja renderer is far out of proportion to this change.
- Enabling or disabling thinking mode. Qwen3 supports `/no_think` and `enable_thinking`; this change consumes whatever the model emits and does not steer it.
- Repairing the download path. Recorded as a constraint below, fixed separately.
- EMLX/EMLXAxon integration, which belongs to `emlx-support`.

## Decisions

### 1. The chat template is a configured string with a prompt placeholder

One `llm_chat_template` config key holds the full template, with `%{prompt}` marking where the user's prompt goes. Qwen3's default is ChatML: `%{prompt}` wrapped in `<|im_start|>user` / `<|im_end|>` and `<|im_start|>assistant`.

**Rationale:** one key expresses everything a single-turn prompt needs, and it is the only shape available given no library support. Making it configurable rather than hardcoded is what stops the next model swap from silently sending the wrong format.

**Alternatives considered:**
- *Hardcode ChatML, as Phi-3's format is hardcoded today.* Rejected: this is the defect being fixed. It would be re-introduced at the next swap, with no test able to catch it.
- *Fetch and render `chat_template.jinja` from the model repo.* Rejected: requires a Jinja implementation, and the template branches on generation mode in ways this store does not model.
- *Named template registry (`"chatml"`, `"phi3"`, …).* Rejected: a lookup table keyed by model family is the same coupling wearing a different hat, and it needs a new entry per model forever. One string per configured model is the honest representation.
- *Separate prefix/suffix config keys.* Rejected: cannot express a template that does not simply wrap the prompt, and invites callers to set one without the other.

### 2. The template travels in `model_ref`, not read from `Config` at inference time

`build_model_ref/3` already has `config` and already stores `tokenizer`, `model`, and `serving` in the returned ref. The template joins them there, so `format_prompt/1` reads `model_ref.chat_template` exactly as it reads `model_ref.tokenizer`.

**Rationale:** it follows the existing pattern, and it keeps the `:sys.replace_state` test seam working. A test can then override the template the same way it overrides `config.loader`, without reaching into application env from inside inference.

**Alternatives considered:**
- *Call `Config.llm_chat_template/0` inside `format_prompt/1`.* Rejected: bypasses the snapshotted config, so a test that swaps `state.config` would not affect it, and inference would read env the rest of the load path does not.
- *Pass config through `run_inference`.* Rejected: changes a function signature to deliver a value that already has a home.

### 3. An empty summary is an error, not a stored value

If stripping reasoning leaves nothing, `generate_summary/2` returns an error tuple. `SummarizationWorker` already routes any non-`:model_loading` error to `JobQueue.fail`, so the job retries, and on exhaustion `nodes.abstract` stays `nil` and `abstract/1` returns the first-line fallback.

**Rationale:** a generation that produced no answer is a failed generation. Returning it as success would be the one outcome worse than the failure, because it writes a value that permanently masks the fallback. Erroring makes the store degrade exactly as it does today when the LLM does not work at all.

**Alternatives considered:**
- *Store the empty string.* Rejected: `"abstract" || fallback` returns `""`, so the document silently reads as empty forever. This is the specific failure the `||` in `agent_db.ex:867` invites.
- *Fall back to the reasoning text.* Rejected: a raw scratchpad is worse content than a first-line fallback, and it is stored as though it were the answer.
- *Retry once with a raised token budget.* Rejected: a real improvement, but it is a retry-policy change, and `Summarization idempotency and retry` already owns that surface. Worth raising separately.

### 4. Model size is configuration, not a literal

A new `llm_model_params` key supplies the string `build_model_status/1` reports, defaulting to the new model's size. The `http-api` scenario stops asserting `"3.8B"` and instead asserts that the value reflects the configured model.

**Rationale:** the literal was duplicated across source and spec, so a model change invalidated a spec assertion — the coupling this change is otherwise removing. Deriving it means the endpoint cannot describe a model the store is not running.

**Alternatives considered:**
- *Update the literal to the new size.* Rejected: smallest diff, but the string stays hand-maintained in two places and drifts at the next swap. Rejected on the same reasoning as the template.

### 5. Strip reasoning by removing the reasoning segment, not by filtering lines

The generated text is scanned for a `<think>` opening marker; everything from that marker up to and including the matching `</think>` is removed, and what follows is trimmed. Text with no marker is returned unchanged apart from trimming.

**Rationale:** a hybrid reasoning model emits reasoning first, so removing the segment preserves the answer regardless of whether the model closed the block. Filtering lines or pattern-matching only a trailing `</think>` would either leave the reasoning in or discard the answer when the block is unterminated.

**Alternatives considered:**
- *Drop any text before the last `</think>`.* Rejected: discards the answer when a model reasons more than once.
- *Ask the model not to think, via `/no_think` or `enable_thinking: false`.* Rejected as the mechanism, because it depends on the model honouring it and varies across Qwen3 revisions. Stripping is unconditional. If the non-thinking route proves reliable it belongs in the generation config, and stripping remains a cheap safety net.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Q4_K_M weights come from a third-party publisher, not Qwen | Recorded explicitly in the proposal. The official repository's q8_0 is a documented alternative; the checksum is whatever the configured URL serves, unchanged from how the current default already works. |
| A 0.6B model summarizes worse than a 3.8B one, with no EMLX work to compensate | This change does not claim to improve summarization. Its purpose is to unblock `emlx-support`, and that trade is stated in the proposal rather than discovered later. |
| `llm_chat_template` is a raw string, so a caller can configure a broken template | Acceptable: the key is only a default, and a wrong template degrades output quality rather than corrupting state. Validating Jinja is out of proportion. |
| The download URL default is renamed but the download remains pointless | Deliberately deferred. `ensure_model_files/3` writing a file nothing reads is a separate defect; changing the default here only stops it naming a model the store no longer uses. |
| `llm_chat_template` and `llm_model_params` add two more env vars to `put_default_config/0` | Accepted. Both have defaults, both are documented in `config/example.exs`, and both remove a hardcoded value that caused this change. |
