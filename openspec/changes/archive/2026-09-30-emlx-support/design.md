## Context

Current architecture (see `lib/agent_db/ml/model_manager.ex`):
- `AgentDb.ML.ModelManager` GenServer loads embedding and LLM models via Bumblebee
- Backend hardcoded to EXLA (CPU default, CUDA/ROCm optional via `exla_backend` config)
- Workers (`EmbeddingWorker`, `SummarizationWorker`) call `ModelManager.embed/1` and `ModelManager.summarize/2`
- Config in `lib/agent_db/config.ex` reads `exla_backend` at runtime

EMLX provides:
- `EMLX` — Nx backend for Apple MLX (GPU/Neural Engine tensor ops)
- `EMLXAxon` — Axon rewrites with Metal shaders for LLM inference acceleration
- Models load from same HuggingFace safetensors/GGUF format

## Goals / Non-Goals

**Goals:**
- Add `ml_backend` config (`:auto` | `:exla` | `:emlx`) with `:auto` default
- On macOS Apple Silicon with `:auto`, prefer EMLX/EMLXAxon; elsewhere EXLA
- Graceful fallback: EMLX init failure → EXLA CPU with warning
- Zero breaking changes to public APIs, workers, job queue, or storage
- Optional deps (EMLX/EMLXAxon) — no forced install on non-macOS

**Non-Goals:**
- New model formats or model switching at runtime
- Metal shader authoring (upstream EMLXAxon handles this)
- Benchmarking/infrastructure for CI (local perf validation only)
- GPU support for non-Apple platforms (CUDA/ROCm stays EXLA)

## Decisions

### 1. Backend selection strategy
**Decision**: `ml_backend` config with three values:
- `:auto` (default) → detect Apple Silicon → EMLX, else EXLA
- `:exla` → force EXLA
- `:emlx` → force EMLX (fail if unavailable)

**Rationale**: Explicit control for users; sensible default for Mac users. No compile-time branching — backend resolved at ModelManager startup.

**Alternatives considered**:
- Compile-time flag (`config :agent_db, ml_backend: :emlx`) — rejected: requires recompile
- Separate ModelManager modules (`ModelManager.Exla`, `ModelManager.Emlx`) — rejected: over-engineered for one config switch
- Auto-detect only (no `:exla`/`:emlx` override) — rejected: users need control for debugging/CI

### 2. EMLX/EMLXAxon as optional dependencies
**Decision**: Add to `mix.exs` with `optional: true`, `runtime: false`, `manager: :mix`. Load conditionally in ModelManager.

**Rationale**: Non-macOS users don't download/build EMLX. Elixir's optional deps mean they're not fetched unless explicitly requested or on matching platform (future mix feature).

**Alternatives considered**:
- Always include — rejected: unnecessary compile-time cost, potential build issues on Linux
- Separate `agent_db_emlx` package — rejected: overkill for backend swap

### 3. Model loading abstraction
**Decision**: Add `ModelManager.Backend` behaviour with `load_embedding/1`, `load_llm/1`, `embed/2`, `summarize/3` callbacks. Two implementations: `Backend.Exla` (current logic), `Backend.Emlx` (new).

**Rationale**: Clean separation; ModelManager delegates to active backend; easy to test; fallback is `try Backend.Emlx, rescue -> Backend.Exla`.

**Alternatives considered**:
- Big `if backend == :emlx` branches in ModelManager — rejected: mixes concerns, hard to test
- Separate GenServer per backend — rejected: overcomplicates supervision tree

### 4. Fallback behavior
**Decision**: On EMLX backend init failure (load error, missing deps, unsupported model), log warning, switch to EXLA, continue. No retry loop.

**Rationale**: Fail-fast with clear signal; user sees warning in logs; system keeps working. Retry adds complexity for marginal benefit.

**Alternatives considered**:
- Silent fallback — rejected: user wouldn't know they're not getting acceleration
- Hard failure — rejected: violates "works offline" principle

### 5. Configuration key naming
**Decision**: `ml_backend` (atom) in `config.ex`, maps to env `AGENT_DB_ML_BACKEND` with string values `"auto" | "exla" | "emlx"`.

**Rationale**: Consistent with existing `exla_backend` naming. String env var for container-friendly config.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| EMLX/EMLXAxon version incompatibility with current Bumblebee/Nx | Pin compatible versions in mix.exs; test on target macOS version |
| Phi-3-mini not supported by EMLXAxon | Fallback to EXLA; document supported models; upstream issue if needed |
| MLX backend slower than EXLA CPU for small batches | Benchmark; if so, default `:auto` can prefer EXLA for embeddings, EMLXAxon for LLM |
| Model download URL changes (HuggingFace) | Already handled — config allows override; same for both backends |
| Optional dep not fetched on macOS in CI | Document `mix deps.get --all` or explicit `:emlx` in CI config |

## Migration Plan

1. Add deps to `mix.exs` (optional)
2. Add `ml_backend/0` to `config.ex`
3. Create `lib/agent_db/ml/model_manager/backend.ex` behaviour
4. Extract EXLA logic to `lib/agent_db/ml/model_manager/backend/exla.ex`
5. Create `lib/agent_db/ml/model_manager/backend/emlx.ex`
6. Refactor `ModelManager` to use behaviour + fallback
7. Update `Application` to conditionally start `:emlx` app
8. Add README section for `ml_backend` config
9. Test on macOS (Apple Silicon) and Linux (EXLA only)

Rollback: Revert `ml_backend` config to `:exla` or remove deps — no data migration needed.

## Open Questions

- Should `:auto` prefer EMLX for both embeddings AND LLM, or only LLM (where EMLXAxon shines)? Can be decided at implementation time.
- Exact EMLX/EMLXAxon version pins — resolve when adding to mix.exs.