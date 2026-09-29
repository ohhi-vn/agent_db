# Proposal

## Why

`AgentDb` currently combines core workflows with direct calls to SQLite, model management, the job queue, and cache/web modules, while application startup assembles those concrete implementations directly. This makes responsibilities difficult to change independently and limits composition to the current providers; introducing explicit boundaries now will make the system easier to understand, test, and extend without changing the established store contract.

## What Changes

- Separate core operations and policies from infrastructure-specific persistence, inference, background processing, caching, and transport concerns.
- Introduce small, owned ports for the replaceable storage, embedding/summarization, and HTTP/WebSocket boundaries, with the existing implementations remaining the defaults.
- Centralize construction and dependency selection at application startup rather than letting core workflows select concrete adapters.
- Keep `AgentDb`'s public API, persisted data and schema, default runtime behavior, and failure/consistency guarantees compatible.
- Add focused boundary and composition tests while retaining regression coverage for existing workflows and invariants.

## Capabilities

### New Capabilities

None. This is a pure internal refactor; it does not add externally observable behavior.

### Modified Capabilities

None. Existing requirements in `context-store`, `vector-search`, `llm-summarization`, `memory`, and `http-api` remain the behavioral contract and must continue to pass unchanged.

This change opts out of delta specs with `skip_specs: true` in `.openspec.yaml` because no spec-level behavior changes.

## Impact

- **Core workflows:** `lib/agent_db/agent_db.ex` currently owns document/tree, search, session, and memory use cases and directly coordinates storage, cache invalidation, and jobs.
- **Infrastructure:** `lib/agent_db/store/` contains SQLite connections and SQL operations; `lib/agent_db/ml/` contains model loading/inference; `lib/agent_db/workers/` and `lib/agent_db/job_queue.ex` implement durable asynchronous work; `lib/agent_db/cache/` owns disposable caches.
- **Composition and transport:** `lib/agent_db/application.ex` starts concrete infrastructure; `lib/agent_db_web/` and `lib/agent_db/web/` expose HTTP and WebSocket surfaces.
- **Compatibility:** preserve public `AgentDb` entry points, SQLite schema and existing on-disk data, URI and result/error contracts, asynchronous job semantics, and optional HTTP lifecycle. No new provider implementation or dependency is required by this change.
- **Existing work:** account for the current Bumblebee loader seam and the in-flight inference/backend changes when defining the inference boundary; do not make those changes depend on transport or storage implementation details.
