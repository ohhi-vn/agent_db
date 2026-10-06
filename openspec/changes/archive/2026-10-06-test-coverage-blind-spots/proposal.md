# Proposal

## Why

Two recent changes shipped behavior that is only thinly covered by committed tests: dim-safe vector routing (mismatch, backfill, prune, coverage) is inert on hosts without sqlite-vec, and provider request shapes (OpenAI `model` field, Ollama batching), remote health semantics, and hybrid-weight shapes were verified with throwaway scripts, never committed tests. The suite is green but the guarantees are verbal.

## What Changes

- Emulate a dim-namespaced vector index in `Fakes.Storage` (per-dim maps, `dim_mismatch` refusal, prune refusal, `active_dim`/`needs_backfill` coverage, missing-only backfill through the existing job flow) so dim-safety *logic* runs deterministically on any host.
- Extend the storage contract with mismatch/backfill/prune/coverage tests that run against both providers (SQLite takes the documented unavailable branch where it must).
- Commit provider-shape tests with a Plug-based fake server: OpenAI `model` in both bodies, Ollama single-batch order preservation plus per-text fallback, healthy-remote health `ok`, fresh-boot `:unknown` dim, and hybrid-weight tuple/list parity.

Non-goals: real sqlite-vec SQL paths (still need an extension host/CI), the parallel-runner drive flakiness (infrastructure, not coverage), any production behavior change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None — test-only change, no spec-level behavior changes (`skip_specs: true`).

## Impact

- Tests/support only: `test/support/provider_fakes.ex`, `test/support/storage_contract.ex`, provider/search test files. No library code, no facade changes, no migrations.
- The emulated index mirrors the specified behavior; it tests application-visible contracts, not the vec0 SQL itself.
