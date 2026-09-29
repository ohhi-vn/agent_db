# Tasks

## 1. Define Core Contracts

- [x] 1.1 Add core-owned storage behaviours and value types for document/tree, session, memory, search, and durable job operations; include atomic subtree purge and guarded persistence callbacks, and verify the callbacks compile and contract tests cover success/error results.
- [x] 1.2 Add the inference contract for embedding, summarization, and model status; verify it with deterministic fake-provider tests, including loading and failure results.
- [x] 1.3 Define transport composition requirements using supervised child specs and the stable application facade; verify a fake transport can be assembled without depending on Phoenix modules.

## 2. Adapt Existing Infrastructure

- [x] 2.1 Make the current SQLite store implement the storage contract without changing its schema; verify CRUD, sessions, memory, search, restart recovery, and atomic subtree-purge contract tests pass against it.
- [x] 2.2 Route workers and durable queue operations through the storage/inference contracts; verify retry/defer behavior and that in-flight embedding or summary results cannot restore a removed or replaced URI.
- [x] 2.3 Make the existing ModelManager/Bumblebee path implement the inference contract while reusing its loader seam; verify embedding normalization/dimensions, summary behavior, model status, and error containment with fakes.
- [x] 2.4 Make Phoenix HTTP/WebSocket transport use application-level operations for health and model status, with no direct SQL or ModelManager calls; verify API behavior and enabled/disabled listener lifecycle tests.

## 3. Move Workflows Behind the Facade

- [x] 3.1 Extract document/tree and search workflows from `AgentDb` into cohesive application modules, then delegate existing public functions; verify URI validation, cache agreement, keyword/vector/hybrid results, and existing error tuples remain unchanged.
- [x] 3.2 Extract session creation, append/read, and commit workflows behind the storage contract; verify ordering, idempotency, removal/recommit restoration, and cache freshness tests pass.
- [x] 3.3 Extract memory validation, recording, recall, supersession, and forgetting policy into a focused workflow; verify taxonomy, provenance/history, subtree scope, and no-summarization behavior tests pass.
- [x] 3.4 Remove remaining direct infrastructure access from core workflows and web contexts; verify dependency-boundary tests show core modules depend only on core contracts and values.

## 4. Compose Providers and Verify Compatibility

- [x] 4.1 Resolve storage and inference implementations once in `AgentDb.Application`, keep current modules as defaults, validate configured implementations at startup, and verify default startup plus custom fake-provider selection and invalid-provider failure.
- [x] 4.2 Compose the optional Phoenix transport through the same startup boundary while preserving `http_enabled`; verify no HTTP listener starts when disabled and the configured listener remains reachable when enabled.
- [x] 4.3 Run the full test suite and formatting checks; verify the public `AgentDb` API, existing SQLite database compatibility, subtree atomicity, job recovery, cache consistency, and transport contracts all pass without spec-level behavior changes.
