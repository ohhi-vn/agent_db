# Tasks

## 1. Reactive subscriptions foundation

- [x] 1.1 Add `AgentDb.subscribe/1` and `unsubscribe/1` over `AgentDb.PubSub` with exact-URI-or-descendant scope validation, verified by `mix test test/subscriptions_test.exs` covering valid, missing-URI watch, invalid-URI error, and sibling exclusion
- [x] 1.2 Broadcast `{:context_changed, uri, kind, version}` from Documents/Memories/Skills/Sessions workflows after commit for write/remove/replace/commit, verified by subscription test asserting one event per change with monotonic version and no content payload
- [x] 1.3 Prove removal and process-lifetime semantics (removed-URI emits once then silences in-flight jobs; exited process and restart clear delivery), verified by removal plus restart integration test

## 2. Pluggable inference providers

- [x] 2.1 Extract local embed/summarize logic behind `Core.Inference` as default provider and add Ollama plus OpenAI-compatible adapters via `Req` with timeout mapping, verified by `mix test test/inference_providers_test.exs` for custom provider, incomplete-provider startup raise, and timeout-to-error mapping without caller exit
- [x] 2.2 Update `vector-search` embedding path and `llm-summarization` L0/L1 paths to use configured provider with local default unchanged, verified by existing `mix test test/vector_search_test.exs test/summarization_test.exs` plus a remote-provider search case preserving result shape
- [x] 2.3 Extend `model_status/0` with provider kind, per-model state, and dimensionality reflecting active config, verified by status test asserting Ollama+local mix and loading-vs-failed distinction

## 3. Elixir structural code index

- [x] 3.1 Implement `Mix`-aware indexer parsing `.ex/.exs` with `Code.string_to_quoted/2` into module/function/macro/behaviour/struct/alias facts stored as ordinary docs under `viking://resources/<project>/code/`, verified by index fixture test asserting `MyApp.User.create/1` facts plus `find`/`grep` reachability with no model loaded
- [x] 3.2 Add OTP-aware relations (supervision chain, GenServer callbacks, callers/callees query), verified by query test returning supervisor chain and two callers for a fixture with ordered URIs and excerpts
- [x] 3.3 Isolate parse failures per file with idempotent re-index, verified by bad-file test where ten valid files land and the invalid one returns a classified error

## 4. Hex docs with version-aware ranking

- [x] 4.1 Discover locked packages from `mix.lock` offline and map to `viking://resources/hex/<pkg>/<version>/`, verified by lockfile fixture test including missing-lockfile `{:ok, []}` case
- [x] 4.2 Ingest README/HexDocs/API per locked version and boost locked-version ranking in hybrid RRF with version metadata on results, verified by 1.7/1.8/1.9 fixture where pinned 1.8 outranks others offline

## 5. BEAM runtime snapshots

- [x] 5.1 Implement read-only `snapshot/1` (nodes/apps/supervisors/process counts/ETS sizes/memory/telemetry/crashes) with bounds, truncation flag, and redaction of bodies/contents/credentials, verified by snapshot test asserting redaction plus truncation on a large-process fixture
- [x] 5.2 Prove snapshot failures are non-disruptive (unreachable node returns classified error, store reads/writes unaffected, never auto-writes), verified by failure-path test

## 6. Channel, observability, and Mix surface

- [x] 6.1 Add `v1.subscribe/unsubscribe` plus retrieval progress pushes (`started/progress/resource_found/memory_found/skill_loaded/assembled`) in existing envelope without changing final search contract, verified by channel test for versioned events, invalid-URI handling, and progress-then-result ordering
- [x] 6.2 Wrap retrieval stages in OTel child spans and telemetry with stage/mode/outcome only (no URIs/content/prompts), verified by trace test asserting per-stage spans and telemetry dimensions plus malformed-parent new-trace case
- [x] 6.3 Add `mix agent_db.index/search/tree/doctor` reusing the `AgentDb` facade alongside `import_skills`, verified by running each task against a tmp `data_dir` and asserting expected output plus help text

## 7. Release verification

- [x] 7.1 Run full suite `mix test` plus `mix run bench/agent_db_bench.exs` smoke check and `openspec validate --change distributed-context-runtime --strict`, verified by clean test run, no absolute-latency regression claim, and validator passing
- [x] 7.2 Update `README.md` and `bench/baseline.md` notes for new APIs, provider config, and deferred cluster scope, verified by doc diff review showing additive-only contracts
