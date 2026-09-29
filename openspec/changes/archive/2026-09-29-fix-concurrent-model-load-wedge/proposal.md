# Proposal

## Why

`ModelManager` tracks the in-flight load with a single `loading_ref` field, but it has two independent roles (`:embedding` and `:llm`). `start_load/3` overwrites that field unconditionally, so when both models begin loading at once the second load's reference clobbers the first, and the first load's result is then rejected as stale by the `handle_cast/3` guard.

The losing load is not reported as failed. Its status stays `:loading` forever, so every later request for that role returns `{:error, :model_loading}` indefinitely. Which role is affected is whichever one started loading first, so on a cold cache one of embedding or summarization silently never becomes available. `model_status/0` reports that role as `state: "loading"`, so the wedge is indistinguishable from a slow load.

This is near-certain to fire rather than a rare race: the application starts the embedding and summarization workers together, the first document write enqueues `:embed` plus both summarization kinds, and the two workers call `ModelManager` within milliseconds of each other while a real load takes seconds to minutes.

## What Changes

- **Track the in-flight load per role.** `loading_ref` becomes a map keyed by role instead of a single `reference() | nil`, so a load result is matched against the reference for *its own* role. A load for `:llm` can no longer invalidate the load for `:embedding`.
- **Keep the stale-result guard.** The reference exists so a result that outlives the manager that started it — after a restart, or after a new load has begun — cannot be adopted. A manager that starts with an empty map rejects any leftover result, so a result from a previous instance is still dropped. The `make_ref/0` reasoning that makes references unique across manager instances is unchanged.
- **Leave the observable load state unchanged.** `{:load_status, role}` replies, `model_status/0`, the `:idle | :loading | :ready | {:failed, reason}` shape, and the grace-period behavior are all as they are. This is a correctness fix to how the in-flight load is identified, not a change to the state machine a caller observes.
- **Cover the interaction.** Add a test that loads both roles concurrently and requires both to reach ready. No existing test overlaps the two roles, which is why this shipped.

Not in scope: model loading and download, the `Nx.Serving` rewrite of inference (tracked separately as `port-inference-to-bumblebee-serving`), backend selection, and splitting a loader process out of `ModelManager`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `vector-search`: `Embedding model management` — the embedding model SHALL become ready when it is loaded, including when a summarization model is loading at the same time. Loading one model SHALL NOT leave the other permanently reporting as loading.
- `llm-summarization`: `LLM model management` — the summarization model SHALL become ready when it is loaded, including when an embedding model is loading at the same time. Loading one model SHALL NOT leave the other permanently reporting as loading.

## Impact

- **Code:** `lib/agent_db/ml/model_manager.ex` — the `loading_ref` write in `start_load/3` and the `loading_ref[role]` read in `handle_cast/3`. `lib/agent_db/ml/model_manager/state.ex` — the `loading_ref` type and its default in the struct.
- **State shape:** `loading_ref` changes from `reference() | nil` to a map keyed by role. The field is internal; nothing outside `ModelManager` and its `State` struct reads it.
- **Behavior:** no caller-visible change to a working system. The change only affects the case where two loads overlap, which currently produces a permanent wedge, so it converts a silent stall into normal progress.
- **Tests:** a new test drives both roles concurrently and requires both to settle ready. Existing load-state tests assert on `{:load_status, role}` and `model_status/0`, neither of which changes.
- **Dependencies:** none.
