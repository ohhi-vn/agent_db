# Proposal

## Why

The store has a documented HTTP error-mapping defect class (wrong statuses, non-JSON-safe error payloads), unbounded transport error shapes, and known performance bottlenecks (single-GenServer inference serialization, single-writer writes, slow tree projection) with no enforced regression gate — clients cannot rely on error responses and operators cannot tell a regression from noise.

## What Changes

- Reproduce-or-close the README-documented HTTP error defects (`POST /api/v1/search` 500 class): invalid modes and unservable searches return JSON-safe 422s on every transport; no error tuple ever reaches an encoder.
- Bound transport error payloads to a machine-readable code set shared with the existing `Observability` classification, so REST, WebSocket, MCP, and CLI report the same reason for the same failure.
- Profile and optimize the bench-covered hot paths (write, keyword search, tree projection) with changes retained only on repeatable measured deltas vs `bench/baseline.md`; no absolute-latency assertions in CI.
- Break `ModelManager` single-GenServer inference serialization behind the unchanged `AgentDb` contracts, measured with warmed models; queue/worker tuning (timeouts, backpressure, retry budgets) keeps existing outcome contracts.
- **BREAKING**: none — error responses become more precise (status codes and code strings), never less; all facade signatures and result shapes stay unchanged.

## Capabilities

### New Capabilities

- None — all work extends existing capabilities.

### Modified Capabilities

- `http-api`: ADDED transport error-mapping requirements — JSON-safe error bodies, correct 4xx/5xx statuses, invalid-mode handling on every transport.
- `runtime-observability`: ADDED bounded error-code requirements — every transport error carries a code from the shared classification; no URIs, content, prompts, users, or credentials in payloads.

## Impact

- Code: `lib/agent_db_web` controllers/channel error rendering, `AgentDb.Observability` code mapping, hot-path storage/search code, `ModelManager` concurrency, worker/queue tuning.
- No dependency, migration, or config changes expected; bench baselines updated only with measured deltas.
- Performance work is deliberately spec-free (implementation detail per project convention — `bench/baseline.md` refuses absolute CI assertions); its acceptance gates live in `tasks.md` as measurement requirements.
