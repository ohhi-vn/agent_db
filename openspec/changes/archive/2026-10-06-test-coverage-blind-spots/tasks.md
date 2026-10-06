# Tasks

## 1. Dim-namespaced vector emulation in fakes

- [x] 1.1 Emulate per-dim vector tables in `Fakes.Storage` (route `put_embedding_result`/`search_vector`/deletes by `byte_size(blob)/4`, refuse absurd dims, cap distinct dims) and verify mixed-dim writes land in separate maps
- [x] 1.2 Emulate `dim_mismatch` (query dim vs active table), prune refusal of the active dim, and `active_dim`/`vectors`/`documents`/`needs_backfill` coverage plus missing-only backfill through the job flow

## 2. Contract tests over both providers

- [x] 2.1 Extend the storage contract with mismatch/backfill/prune/coverage tests and verify green against SQLite (unavailable-branch where the extension is absent) and fakes (emulated-branch)

## 3. Committed provider-shape and semantics tests

- [x] 3.1 Commit Plug-based fake-server tests: OpenAI `model` in `/embeddings` and `/chat/completions` bodies, Ollama single-batch order preservation plus per-text fallback on rejection
- [x] 3.2 Commit status semantics tests: healthy-remote health `ok` vs unreachable `degraded`, fresh-boot `:unknown` dim until first embed, and hybrid-weight tuple/list ranking parity
- [x] 3.3 Run the full affected suites file-by-file plus `openspec validate` and verify green
