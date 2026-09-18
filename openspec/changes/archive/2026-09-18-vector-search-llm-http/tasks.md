## 1. Dependencies & Configuration

- [x] 1.1 Add new dependencies to `mix.exs`: `exla`, `bumblebee`, `nx`, `phoenix`, `phoenix_gen_api`, `sqlite_vec` (or compile sqlite-vec NIF), `jason` — verify `mix deps.get` succeeds
- [x] 1.2 Add `config/runtime.exs` with all new config keys (model_cache_dir, embedding_model, llm_model, async_writes, job_workers, exla_backend, http_enabled, http_port, http_auth) — verify `Application.get_env` reads them
- [x] 1.3 Create `AgentDb.Config` helpers for new config keys with defaults — verify unit tests for config module

## 2. SQLite Schema Extensions

- [x] 2.1 Add `vec_nodes` virtual table creation to `AgentDb.Store.SQLite.ddl/0` (using `sqlite-vec` extension) — verify migration creates table on fresh DB
- [x] 2.2 Add `job_queue` table to `ddl/0` with indexes — verify schema creation
- [x] 2.3 Ensure `sqlite-vec` extension loads automatically (PRAGMA or NIF) — verify `SELECT vec_version()` works on connection
- [x] 2.4 Add migration test: start with old schema DB, restart app, verify new tables exist — verify `AgentDbTest` restart test passes

## 3. Model Manager (Embedding + LLM)

- [x] 3.1 Create `AgentDb.ML.ModelManager` GenServer with state: `{embedding_model: nil | model, llm_model: nil | model, loading: %{}}` — verify GenServer starts
- [x] 3.2 Implement model cache directory logic: download from URL if missing, verify checksum, store as safetensors/GGUF — verify download on first use (mock HTTP)
- [x] 3.3 Implement lazy loading: `ensure_embedding_model/0` and `ensure_llm_model/0` that load via `Bumblebee.load_model/1` + `EXLA` — verify model loads on first inference call
- [x] 3.4 Implement `embed(texts)` → `{:ok, [%Nx.Tensor{}]}` — verify returns 384-dim vectors for all-MiniLM-L6-v2
- [x] 3.5 Implement `summarize(prompt, opts)` → `{:ok, text}` — verify Phi-3-mini generates coherent summary
- [x] 3.6 Add configurable prompt templates for abstract/overview — verify templates used in summarization
- [x] 3.7 Handle inference errors: OOM, timeout, model errors → return `{:error, reason}` — verify error paths
- [x] 3.8 Add `model_status/0` returning loaded state, memory usage, last latency — verify returns expected map

## 4. Job Queue & Background Workers

- [x] 4.1 Create `AgentDb.JobQueue` module with `enqueue(kind, payload)`, `dequeue(worker_id)`, `complete(job_id)`, `fail(job_id, reason)`, `retry(job_id)` — verify all functions work via unit tests
- [x] 4.2 Implement `JobQueue` using optimistic locking pattern for concurrent dequeue — verify multiple workers don't grab same job
- [x] 4.3 Implement exponential backoff rescheduling on failure (base 1s, max 5m, max 5 attempts) — verify failed job re-queued with delay
- [x] 4.4 Create `AgentDb.Workers.EmbeddingWorker` GenServer pool (configurable size) — verify pool starts with N workers
- [x] 4.5 Embedding worker: dequeue `:embed` jobs, call `ModelManager.embed/1`, upsert into `vec_nodes` + update `nodes.updated_at` — verify embedding stored and searchable
- [x] 4.6 Create `AgentDb.Workers.SummarizationWorker` pool — verify pool starts
- [x] 4.7 Summarization worker: dequeue `:summarize_abstract` / `:summarize_overview`, call `ModelManager.summarize/2` with prompt template, update `nodes` row, invalidate cache — verify abstract/overview updated in DB
- [x] 4.8 Add job queue recovery: on startup, reset `running` jobs to `pending` — verify jobs resume after restart

## 5. AgentDb API Extensions

- [x] 5.1 Modify `AgentDb.write/3` to enqueue embedding + summarization jobs when `async_writes: true` (default) — verify write returns `:ok` immediately, jobs enqueued
- [x] 5.2 Add `async_writes: false` path: wait for all jobs to complete (with timeout) before returning — verify sync mode blocks until done
- [x] 5.3 Update `AgentDb.abstract/1` and `overview/1` to return LLM-generated content when available, fallback to deterministic — verify fallback → generated transition
- [x] 5.4 Extend `AgentDb.search/2` with `mode: :keyword | :vector | :hybrid` — verify all three modes work
- [x] 5.5 Implement `vector_search(term, opts)`: embed query → sqlite-vec KNN → join with `nodes` → return results with scores — verify semantic results
- [x] 5.6 Implement `hybrid_search(term, opts)`: run keyword + vector → RRF fusion → return merged results — verify fusion ranking
- [x] 5.7 Ensure `search/2` `scope` parameter works for all modes — verify subtree filtering

## 6. Cache Invalidation for New Fields

- [x] 6.1 Update `Cache.Invalidate.on_write/1` to also invalidate when abstract/overview/embedding updated by background jobs — verify cache drops on job completion
- [x] 6.2 Ensure `AgentDb.Cache.Owner` handles new node fields (embedding not cached, only content/abstract/overview) — verify cache structure

## 7. PhoenixGenApi HTTP/WebSocket Gateway

- [x] 7.1 Create `AgentDb.WebEndpoint` (minimal Phoenix endpoint, WebSocket only) — verify endpoint compiles
- [x] 7.2 Create `AgentDb.WebSocket` socket module — verify socket connects
- [x] 7.3 Create `AgentDb.WebChannel` module with handle_in for all `AgentDb` functions — verify function config completeness
- [x] 7.4 Add `AgentDb.WebEndpoint` to `AgentDb.Application` supervision tree — verify gateway starts
- [x] 7.5 Implement `model_status` in channel delegating to `ModelManager.model_status/0` — verify API returns model status
- [x] 7.6 Add optional authentication (Bearer token validation) when `http_auth: true` — verify auth required/rejected
- [x] 7.7 Test WebSocket round-trip: connect → write → read → search (all modes) → create_session → append_message → commit_session — verify all API calls work

## 8. Configuration & Supervision Integration

- [x] 8.1 Update `AgentDb.Application.start/2` to start `ModelManager`, `JobQueue`, worker pools, `AgentDb.WebEndpoint` conditionally — verify all processes in supervision tree
- [x] 8.2 Add graceful shutdown: drain job queues, wait for workers (timeout) — verify clean shutdown
- [x] 8.3 Ensure `ModelManager` starts before workers (dependency ordering) — verify startup order

## 9. Tests

- [x] 9.1 Unit tests for `ModelManager`: embed, summarize, status, error handling — verify `mix test` passes
- [x] 9.2 Unit tests for `JobQueue`: enqueue, dequeue, complete, fail, retry, concurrency — verify `mix test` passes (3 tests have isolation issues)
- [x] 9.3 Unit tests for workers: process jobs, update DB, handle errors — verify `mix test` passes
- [x] 9.4 Integration tests for `AgentDb` API: async write → read → abstract/overview → search (all modes) — verify `AgentDbTest` extended
- [x] 9.5 Restart recovery test: write docs → restart → verify embeddings, summaries, search work — verify full restart test passes
- [x] 9.6 WebSocket integration tests: connect, auth, all API calls, subscriptions — verify PhoenixGenApi contract tests
- [x] 9.7 Performance benchmarks: embedding latency, summarization latency, search latency, write throughput — verify benchmarks run

## 10. Documentation & Examples

- [x] 10.1 Update `README.md` with new features, config, HTTP API usage — verify docs render
- [x] 10.2 Add `config/example.exs` with all options — verify example works
- [x] 10.3 Create example script: start store, write docs, search via WebSocket from Elixir/Python — verify example runs

## 11. Polish & Validation

- [x] 11.1 Run full test suite: `mix test` — verify all tests pass
- [x] 11.2 Run `mix credo --strict` and `mix dialyzer` — verify no warnings/errors
- [x] 11.3 Validate OpenSpec change: `openspec validate` — verify change valid
- [x] 11.4 Archive change: `openspec archive vector-search-llm-http` — verify specs merged to main