# Tasks

## 1. Store layer

- [x] 1.1 Add a `memory_meta` table to `base_ddl/0` in `lib/agent_db/store/sqlite.ex` with columns for the assertion id, memory URI, value, confidence, source, status (`active` / `superseded`), a self-referencing `supersedes` pointer, and created/updated timestamps — verify `mix compile` succeeds and `ensure_schema/1` creates the table idempotently across two calls
- [x] 1.2 Index `memory_meta` on `(uri, status)` and on `status` — verify the indexes exist after schema creation
- [x] 1.3 Add store functions for recording an assertion, marking the prior assertion at a URI superseded in the same transaction, and reading a URI's active assertion plus its superseded chain — verify each returns `{:ok, _}` or `{:error, _}` and that the supersede transition is atomic
- [x] 1.4 Add a store function that deletes a URI's memory and all of its assertion rows in one transaction — verify no assertion rows for that URI remain afterwards

## 2. Commit-path cache fix

- [x] 2.1 Invalidate the read-through cache for the destination URI in `persist_commit/4` in `lib/agent_db/agent_db.ex`, so a commit brings the cache to the state a cold cache would produce — verify with a test that reads a URI, commits a changed session to it, and reads again, asserting the second read returns the committed content
- [x] 2.2 Assert the same read equals a read that bypasses the cache (SQLite fallback path) — verify the test covers both the cached and uncached read for the committed destination

## 3. Memory API

- [x] 3.1 Define the memory type taxonomy (`profile`, `preferences`, `entities`, `events`, `experiences`) and the fixed memories root, plus the default confidence, in `lib/agent_db/agent_db.ex` — verify an unrecognised type is rejected with an error naming the type
- [x] 3.2 Implement `remember/3`: validate the URI is beneath the memories root and the type is in the taxonomy, persist the value as a document through the existing write path, enqueue an embedding job and no summarization jobs, and record the assertion — verify recording succeeds with no model loaded and that no `:summarize_*` job was enqueued
- [x] 3.3 Implement revision: recording at a URI that already holds a memory marks the prior assertion superseded, links it to its successor, and updates the document content in place rather than creating a second node — verify exactly one active assertion remains and every superseded row names its successor
- [x] 3.4 Implement `recall/1` supporting recall by URI, by subtree, by type, and by optional term, returning only active assertions and ordering multiple results by descending confidence — verify superseded rows are excluded, confidence ordering holds, and a term matching nothing returns an empty result rather than an error
- [x] 3.5 Include confidence and source in recall results, defaulting confidence when the caller omits it — verify a caller-supplied confidence and source round-trip and that an omitted confidence yields the documented default
- [x] 3.6 Implement `forget/1`: remove the document and all assertion rows for the URI — verify a subsequent recall and read report it absent, no confidence/source/superseded history remains, other memories are unaffected, and forgetting a URI with no memory reports that none was found. Hard delete is the only mode, so there is no options argument
- [x] 3.7 Expose the superseded chain for inspection, reporting the prior value and the assertion that superseded it — verify a revised memory returns its history

## 4. Integration with existing paths

- [x] 4.1 Verify a recorded memory is reachable through ordinary tree navigation (`list/1`, `tree/2`, `read/1`) and through a term `search/2` scoped to the memories root, with no memory-specific branch in any of those paths — verify each operation returns the memory
- [x] 4.2 Verify the memory API works end to end while vector and hybrid search are unavailable — verify `remember/3` and a keyword `recall` both succeed with no model loaded and no network access

## 5. Documentation

- [x] 5.1 Document `remember/3`, `recall/1`, and `forget/2` in the README with the taxonomy, the memories root, the default confidence, and a worked supersession example — verify the examples match the implemented signatures
- [x] 5.2 State in the README that memories embed but are not summarized, and why — verify the claim matches the job policy implemented in task 3.2
