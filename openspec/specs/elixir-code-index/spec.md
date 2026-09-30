# elixir-code-index Specification

## Purpose
Makes Elixir projects queryable by structure instead of text chunks, so agents can answer caller/callee, behaviour, and supervision questions deterministically without an LLM.

## Requirements

### Requirement: Structural Elixir source ingestion
The system SHALL ingest local `.ex` and `.exs` files by parsing with `Code.string_to_quoted/2` and extracting Module, function, macro, behaviour, protocol, struct, alias, and dependency relations. Each ingested file SHALL be stored as an ordinary document under `viking://resources/<project>/code/` with its full content as L2 and its structural facts attached as retrievable metadata. Ingestion SHALL require no language model and SHALL NOT change existing `write/read/search/find/grep` contracts for non-code documents.

#### Scenario: Index an Elixir module
- **WHEN** a project file defines `defmodule MyApp.User` with functions `create/1` and `get/1`
- **THEN** the index holds a code document for that file plus facts for the module and both functions
- **AND** `find` for `User` and `grep` for `def create` both reach the stored file

#### Scenario: Ingestion needs no model
- **WHEN** sources are indexed while no embedding or LLM model is cached or reachable
- **THEN** structural facts are still stored and queryable by exact name
- **AND** no `:model_loading` error is reported for the structural query path

### Requirement: OTP-aware relations
The index SHALL record supervision and callback relations: Application to Supervisor to worker, `DynamicSupervisor` children, and `GenServer`/`GenStage`/`Task` callbacks (`init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `terminate/2`). A query for a module SHALL be able to return its supervisor chain, its callbacks, and its callers and callees as URI references with bounded excerpts.

#### Scenario: Explain a GenServer crash structurally
- **WHEN** an agent asks for `MyApp.Worker` and it is supervised by `MyApp.Supervisor`
- **THEN** the result identifies the supervisor chain, the callbacks the worker implements, and the URIs holding each callback's source

#### Scenario: Find callers of a function
- **WHEN** `MyApp.User.create/1` is called from two project modules
- **THEN** a structural query for its callers returns both calling modules with file URIs and line excerpts ordered by URI

### Requirement: Parse failures are isolated
A file that fails to parse SHALL be reported as an error for that file only and SHALL NOT abort indexing of other files, terminate the caller, or leave a partially written code subtree. Re-indexing an unchanged file SHALL NOT duplicate its facts.

#### Scenario: One bad file does not stop indexing
- **WHEN** one source file contains a syntax error and ten others are valid
- **THEN** the ten valid files are indexed and the invalid one returns a classified parse error
- **AND** a later fix and re-index of that file replaces only its facts
