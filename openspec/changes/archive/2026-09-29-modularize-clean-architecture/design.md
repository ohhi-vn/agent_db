# Design

## Context

See `proposal.md` for motivation and compatibility scope. The current `AgentDb` module coordinates document/tree, search, session, and memory workflows while directly calling `Store.Reader`, `Store.Writer`, SQL helpers, `JobQueue`, cache invalidation, and `ML.ModelManager`. `AgentDb.Application` starts these concrete processes, and Phoenix code generally calls the facade but `AgentDbWeb.Context` also reads SQLite and model state directly.

The existing contracts require more than preserving return values: subtree removal is atomic across URI-keyed state; work already in flight cannot recreate removed data; persisted jobs recover after restart; writes commit before cache invalidation and acknowledgement; and current on-disk SQLite data remains readable. The model loader already has an injectable seam, and active inference/backend changes also touch this area.

## Goals / Non-Goals

**Goals:**

- Make dependency flow point inward: workflows depend on core-owned contracts and values, while SQLite, the current inference stack, ETS, job execution, and Phoenix implement or use those contracts at the edges.
- Keep storage, inference, and transport replaceable through explicit composition, with today's implementations as defaults.
- Make public `AgentDb` functions a stable facade over focused use cases; group responsibilities by capability instead of reproducing the current monolith in a new generic service.
- Preserve existing behavior and operational guarantees without a schema migration.

**Non-Goals:**

- Add or select a second database, model runtime, or transport implementation.
- Change public `AgentDb` function signatures, wire formats, SQLite schema, URI rules, queue policy, or the default HTTP behavior.
- Turn every internal helper or process into a plugin point; extension boundaries are limited to the three requested external concerns.

## Decisions

### 1. Keep `AgentDb` as the compatibility facade and move workflows into focused application modules

Public functions remain in `AgentDb` and delegate to application/use-case modules for document/tree operations, search, sessions, and memory. URI validation, memory taxonomy and supersession policy, search fusion, and result/error translation belong with those workflows or core value modules. SQL shape, connection ownership, model-library calls, cache tables, and Phoenix request/socket details stay outside them.

The operations are grouped by cohesive capability rather than creating a module for each function. This permits an incremental move and makes ownership visible without adding layers that merely forward calls.

**Alternative considered:** Keep all logic in `AgentDb` and extract only the largest helpers. This reduces file movement but leaves database, model, and transport dependencies inside the workflow owner, so the requested composition boundary remains absent.

### 2. Define core-owned behaviors at use-case boundaries

Introduce a storage contract for operations needed by workflows, including document/tree and session/memory persistence, search queries, and durable background-job operations. The contract must express transactions and conditional writes/removals at the operation level; workflows must not receive raw SQLite connections or issue SQL. `AgentDb.Store.SQLite` remains the default adapter and owns the related schema, connection pools, and SQL mappings.

Introduce an inference contract for embedding, summarization, and model status. `AgentDb.ML.ModelManager` and its current Bumblebee loader remain the default implementation path; model download/lifecycle and serving details stay behind it. Keep embedding and summary calls distinct so a workflow requests only the capability it needs. Reuse the existing Bumblebee loader seam and align its adapter contract with the in-flight serving/backend changes rather than building a second model-loading path.

Transport remains an outer adapter contract: transports receive the application facade/use cases and own protocol parsing, authentication, rendering, and lifecycle. The Phoenix HTTP/WebSocket implementation is the default optional transport; web contexts must not query SQL or call the model manager directly for status/health.

Behaviours are justified here because the user-requested variation is at these specific boundaries. They are not added to internal helpers, cache modules, or individual use cases. Contract callbacks should exchange core types and explicit `{:ok, _}` / `{:error, _}` results, not adapter-specific structs or exceptions.

**Alternative considered:** Use a generic service locator or pass unconstrained maps of callbacks. Those make dependencies harder to discover and validate and weaken the contract between core and adapters. Behaviours keep required operations inspectable and testable in Elixir.

### 3. Keep durable state and consistency ownership together in the storage adapter

The storage adapter owns the durable node/session/memory records, vector-index state, and persisted job queue operations that must agree on removals and writes. It exposes high-level operations that preserve the existing SQLite adapter's transaction boundary. In particular, removing a subtree must atomically purge every URI-keyed record and cancel queued work; result persistence from an in-flight embedding or summary must be fenced against a removed or replaced node.

This contract prevents a future adapter from claiming compatibility while leaving orphaned jobs/index entries or allowing stale background work to recreate deleted state. It does not require every future database to use SQLite transactions internally, but it does require equivalent observable atomicity and concurrency behavior.

**Alternative considered:** Split jobs, vectors, and documents into unrelated adapters immediately. That would make their coordinated cleanup and in-flight race guarantees dependent on a new distributed transaction/outbox design, which is unnecessary for this refactor and risks weakening current invariants.

### 4. Compose selected adapters once at application startup

`AgentDb.Application` is the composition root. It resolves configured storage, inference, and transport implementations, validates required callbacks/options, obtains supervised child specs, and wires application workflows to them. Existing modules are the defaults, so current deployments require no new configuration. Explicit module selection is available for tests and integrations; missing, invalid, or failed adapters produce a startup error rather than silently substituting a different implementation.

HTTP remains opt-in through the existing `http_enabled` setting. Transport child specs compose with the core supervision tree and must respect start/stop order. Provider configuration is read when the application is composed, rather than being re-resolved differently by each workflow.

**Alternative considered:** Add providers dynamically after startup or have each use case read application environment on every call. This spreads composition logic, makes lifecycle and tests nondeterministic, and allows configuration changes to produce partially switched dependencies.

### 5. Keep cache an internal optimization and test through the owning boundary

ETS remains disposable and is not a required storage provider. Read-through, invalidation, and any cache wrapper stay owned by the application/storage integration, with writes persisting before acknowledgement and invalidation. Core workflows do not inspect ETS. Adapter contract tests verify persistence and atomic operations; workflow tests verify policy and result mapping; integration tests verify startup composition and the existing cross-component invariants.

**Alternative considered:** Expose cache as a fourth pluggable port. No independent cache variation was requested, and doing so would enlarge the public extension surface without improving the required storage, inference, or transport composition.

## Risks / Trade-offs

- [Broad responsibility migration can change subtle behavior such as cache freshness, session commit idempotency, memory history, or error tuples] → Move cohesive workflows in small slices and keep the current invariant and public API suites passing at each step.
- [A storage contract that is too low-level leaks SQL; one that is too broad can become a second monolithic facade] → Define callbacks around coherent repository operations and atomic invariants, then implement contract tests against the SQLite adapter.
- [Independent storage components could break atomic deletion or allow stale background results to return] → Keep durable URI-keyed state and job/index coordination under one storage contract, and require guarded result persistence for in-flight work.
- [Public adapter behaviors and configuration become a compatibility surface] → Keep callbacks narrow, documented, and limited to storage, inference, and transport; retain defaults and fail fast on invalid implementations.
- [The existing `AgentDbWeb.Context` bypasses the facade for health/model status] → Route these reads through application-level status contracts before treating transport as isolated.
- [Inference changes are concurrently evolving] → Adapt the existing loader/provider path once, preserve embedding dimensionality/normalization and summary error semantics, and avoid coupling adapter selection to an unfinished inference implementation detail.

## Migration Plan

1. Define core values and behavior contracts from current call sites and invariants; add contract tests for storage, inference, and transport boundaries.
2. Wrap the current SQLite, ModelManager/Bumblebee, ETS/cache, and Phoenix implementations without changing their behavior or the persisted schema.
3. Move cohesive workflows behind the compatibility facade in slices, beginning with one capability at a time; remove direct infrastructure calls from each moved workflow and web context.
4. Wire the default implementations through the application composition root, then add explicit adapter substitution tests and verify startup failure for invalid adapters.
5. Run the existing test suite plus focused contract/integration tests, including atomic subtree removal, stale background-job fencing, restart recovery, cache consistency, and HTTP enabled/disabled lifecycle.

The migration is backward-compatible at the data and public API levels, so rollback is to the prior code version using the unchanged SQLite database. New adapter configuration must default to the existing modules; if rollout exposes a defect, remove the new selection and restore the previous composition without transforming persisted data.
