## 1. Dependencies & Configuration

- [x] 1.1 Add `{:emlx, "~> 0.1", optional: true, runtime: false, manager: :mix}` and `{:emlx_axon, "~> 0.1", optional: true, runtime: false, manager: :mix}` to `mix.exs` deps — verify `mix deps.get` succeeds
- [x] 1.2 Add `ml_backend/0` function to `lib/agent_db/config.ex` reading `AGENT_DB_ML_BACKEND` env var with values `"auto" | "exla" | "emlx"` defaulting to `:auto` — verify `iex -S mix run -e "IO.inspect AgentDb.Config.ml_backend()"` returns correct atom

## 2. Backend Abstraction

- [x] 2.1 Create `lib/agent_db/ml/model_manager/backend.ex` behaviour module with callbacks: `load_embedding/1`, `load_llm/1`, `embed/2`, `summarize/3`, `model_info/0` — verify `mix compile` succeeds
- [x] 2.2 Create `lib/agent_db/ml/model_manager/backend/exla.ex` implementing the behaviour, extracting current EXLA logic from `ModelManager` — verify `mix compile` succeeds
- [x] 2.3 Create `lib/agent_db/ml/model_manager/backend/emlx.ex` implementing the behaviour using EMLX/EMLXAxon — verify `mix compile` succeeds (may need conditional compile guards)

## 3. ModelManager Refactor

- [x] 3.1 Refactor `lib/agent_db/ml/model_manager.ex` to:
  - Read `ml_backend` config at init
  - Select backend module (`Backend.Exla` or `Backend.Emlx`) with fallback logic
  - Delegate `embed/1`, `summarize/2`, `model_status/0` to backend
  - Log warning on EMLX fallback — verify `mix compile` succeeds
- [x] 3.2 Update `lib/agent_db/application.ex` to conditionally start `:emlx` application when backend is `:emlx` or `:auto` on macOS — verify app starts without errors

## 4. Testing & Verification

- [x] 4.1 Add unit test for `Config.ml_backend/0` parsing env var correctly — verify `mix test` passes
- [x] 4.2 Add test for `Backend.Exla` behaviour implementation — verify `mix test` passes
- [x] 4.3 Add test for `ModelManager` backend selection and fallback (mock EMLX failure) — verify `mix test` passes
- [x] 4.4 Manual verification on macOS Apple Silicon: set `ml_backend: :emlx`, write document, confirm embedding/summarization works — verify logs show EMLX backend selected, no fallback warning
- [x] 4.5 Manual verification on macOS: force EMLX failure (remove deps or corrupt model), confirm fallback to EXLA with warning log — verify warning appears, operations succeed

## 5. Documentation

- [x] 5.1 Add `ml_backend` configuration to README with environment variable docs and example values — verify README renders correctly
- [x] 5.2 Add note about optional EMLX deps and macOS-only acceleration — verify README renders correctly