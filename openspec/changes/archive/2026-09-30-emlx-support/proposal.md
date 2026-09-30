## Why

Currently, `agent_db` runs embedding generation and LLM summarization exclusively via **Bumblebee + EXLA** on CPU (default) or CUDA/ROCm. On macOS with Apple Silicon, this leaves the Neural Engine and GPU idle. **EMLX** provides an Nx backend for Apple's MLX framework, and **EMLXAxon** provides Metal shader-accelerated LLM inference — offering 3-10x speedups for local LLM workloads on Mac. Adding EMLX support unlocks this performance with zero external dependencies, keeping the project's pure offline-first architecture intact.

## What Changes

- Add `{:emlx, "~> 0.1"}` and `{:emlx_axon, "~> 0.1"}` as optional dependencies (macOS-only runtime)
- Introduce a new `ml_backend` config option: `:auto` (default), `:exla`, or `:emlx`
- Auto-detect Apple Silicon at startup; when `:auto`, prefer EMLX on macOS, EXLA elsewhere
- Modify `AgentDb.ML.ModelManager` to load models via the selected backend
- Update `EmbeddingWorker` and `SummarizationWorker` to work unchanged (they call `ModelManager`)
- Add graceful fallback: if EMLX initialization fails, log warning and fall back to EXLA CPU
- Keep existing model IDs (all-MiniLM-L6-v2, Phi-3-mini) — EMLX loads safetensors/GGUF via HuggingFace Hub
- No breaking changes to public APIs or storage formats

## Capabilities

### Modified Capabilities

- **llm-summarization**: Requirement "LLM model management" — backend selection now includes EMLX/EMLXAxon as an option; inference latency scenarios implicitly benefit from acceleration
- **vector-search**: Requirement "Embedding model management" — embedding model can now run on MLX backend; generation latency scenarios implicitly benefit

No new capabilities. This is a **backend implementation swap** with identical behavioral contracts.

## Impact

| Area | Change |
|------|--------|
| `mix.exs` | Add `emlx`, `emlx_axon` deps (optional, runtime: false, manager: :mix) |
| `lib/agent_db/config.ex` | Add `ml_backend/0` function with `:auto` default |
| `lib/agent_db/ml/model_manager.ex` | Backend-aware model loading; fallback logic |
| `lib/agent_db/application.ex` | Ensure EMLX application starts if selected |
| Documentation | Document `ml_backend` env var in README |
| Tests | Verify fallback behavior; existing tests cover behavioral contracts |

No changes to SQLite schema, URI structure, job queue, or public APIs.