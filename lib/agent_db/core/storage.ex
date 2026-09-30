defmodule AgentDb.Core.Storage do
  @moduledoc """
  Durable state the context store keeps, expressed without reference to any
  particular database.

  A storage adapter owns every record keyed by URI -- documents, the vector
  index, the persisted job queue, session commit bookkeeping, and memory
  assertions -- because those records have to agree with each other. The
  contract therefore exposes whole operations rather than connections or
  statements: a workflow asks for a subtree to be removed, not for a
  transaction to be opened.

  ## Invariants an implementation must uphold

    * A write is durable before it is acknowledged, and a cache in front of the
      adapter may never serve anything the adapter has not already committed.
    * `remove_subtree/1` removes a URI and everything beneath it from *every*
      store keyed by URI, in one atomic step. A rejected removal leaves all
      state untouched.
    * `replace_skill/2` has the same two properties for a whole subtree: the
      previous contents of the URI, the new ones, and the work enqueued for
      them all land together or not at all.
    * A result produced by work that started before a removal never brings the
      removed URI back. `put_embedding_result/3` and `put_layer_result/4`
      check that the node is still there on the same connection that writes the
      result, and report `:discarded` when it is not.

  Callbacks exchange core values and `{:ok, _}` / `{:error, _}` results, never
  adapter-specific structs or exceptions.
  """

  @typedoc "A stored document or directory."
  @type tree_node :: %{
          uri: String.t(),
          parent_uri: String.t() | nil,
          name: String.t(),
          kind: :doc | :dir,
          content: String.t() | nil,
          abstract: String.t() | nil,
          overview: String.t() | nil
        }

  @typedoc "One file of a skill, at `path` below the skill's root."
  @type skill_file :: %{path: [String.t()], content: String.t()}

  @typedoc "One assertion ever made at a memory's URI."
  @type memory_row :: %{
          id: integer(),
          uri: String.t(),
          value: String.t(),
          confidence: float(),
          source: String.t() | nil,
          status: :active | :superseded,
          supersedes: integer() | nil,
          updated_at: integer()
        }

  @typedoc "One message of a session, in order."
  @type message :: %{seq: integer(), role: atom(), content: String.t()}

  @typedoc "A unit of durable background work."
  @type job :: %{
          id: integer(),
          kind: atom(),
          payload: map(),
          attempts: integer(),
          max_attempts: integer()
        }

  @typedoc "A vector search hit, scored by the adapter."
  @type hit :: %{
          uri: String.t(),
          content: String.t() | nil,
          abstract: String.t() | nil,
          overview: String.t() | nil,
          score: float()
        }

  @typedoc "A path-discovery match: URI, name, and node kind, without document content."
  @type path_match :: %{
          uri: String.t(),
          name: String.t(),
          kind: :doc | :dir
        }

  @typedoc "A content line match: document URI, one-based line number, and bounded excerpt."
  @type line_match :: %{
          uri: String.t(),
          line_number: pos_integer(),
          excerpt: String.t()
        }

  @typedoc "The layered summary a background worker produced."
  @type layer :: :abstract | :overview

  @doc "Supervised children the adapter needs, given the resolved `path` to the database file."
  @callback child_specs(keyword()) :: [Supervisor.child_spec() | module()]

  @doc "The node at `uri`, or `{:ok, nil}` when nothing is stored there."
  @callback get_node(String.t()) :: {:ok, tree_node() | nil} | {:error, term()}

  @doc """
  Writes a document at `uri`, creating missing parent directories.

  `:abstract` and `:overview` in `opts` are the caller's own layers; `nil` for
  either keeps whatever is already stored, so a re-write does not discard a
  layer it did not supply.

  `:jobs` in `opts` is the required background work for the write, as a list
  of `{kind, payload}` pairs. A provider persists the document and all jobs
  as one storage outcome: success means both are durable, and a failure to
  persist or enqueue any job leaves prior document, cache, and queue state
  unchanged.
  """
  @callback put_document(String.t(), String.t(), keyword()) :: {:ok, :ok} | {:error, term()}

  @doc "Names of `uri`'s direct children, sorted. `{:error, :not_found}` when the URI holds no directory."
  @callback list_children(String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Removes `uri` and its whole subtree from every store keyed by URI."
  @callback remove_subtree(String.t()) :: :ok | {:error, :not_found} | {:error, :is_root}

  @doc """
  Replaces the whole subtree at `uri` with `files`, in one atomic step.

  Each `file` is stored at `uri` followed by its `path`, with the directories
  above it created, and the usual asynchronous work is enqueued for it, so a
  file written this way is indistinguishable from one written with
  `put_document/3`.

  What was at `uri` before is removed, from every store keyed by URI, in the same
  step: a file the new set does not mention must not survive it, and a failure
  part way through must leave the previous contents exactly as they were.

  Answers whether anything was there to replace, which is what tells a caller
  that an import overwrote a skill rather than adding one.
  """
  @callback replace_skill(String.t(), [skill_file()]) ::
              {:ok, %{replaced: boolean(), files: pos_integer()}} | {:error, term()}

  @doc "Stores a generated summary for a job, unless its node has since been removed."
  @callback put_layer_result(integer(), String.t(), layer(), String.t()) ::
              {:ok, :stored | :discarded} | {:error, term()}

  @doc "Stores a generated embedding for a job, unless its node has since been removed."
  @callback put_embedding_result(integer(), String.t(), binary()) ::
              {:ok, :stored | :discarded} | {:error, term()}

  @doc "Case-insensitive substring search over stored documents, optionally within `scope_prefix`."
  @callback search_keyword(String.t(), String.t() | nil) ::
              {:ok, [tree_node()]} | {:error, term()}

  @doc "Nearest neighbours of a query embedding, optionally within `scope_prefix`."
  @callback search_vector(binary(), pos_integer(), String.t() | nil) ::
              {:ok, [hit()]} | {:error, term()}

  @doc """
  Path-discovery matches for `query` within `scope_uri` or beneath it.

  `query` is a validated literal substring (1 through 256 characters).
  `scope_uri` is a validated exact URI or `nil` for the whole tree; scope
  membership is exact-URI-or-descendant, so `scope` never matches a sibling
  such as `scope-old`. Matching is case-insensitive over the URI path
  (excluding the `viking://` scheme), `%`, `_`, and `\\` match literally,
  results are ordered by URI, and at most `limit` entries are returned
  without document content.
  """
  @callback find_paths(String.t(), String.t() | nil, pos_integer()) ::
              {:ok, [path_match()]} | {:error, term()}

  @doc """
  Line matches for `query` in full document content (L2) within `scope_uri`
  or beneath it.

  `query` is a validated literal substring (1 through 256 characters).
  `scope_uri` is a validated exact URI or `nil` for the whole tree; scope
  membership is exact-URI-or-descendant. Matching is case-insensitive over
  L2 content only (abstracts and overviews never match), `%`, `_`, `\\`,
  and regular-expression metacharacters match literally, results are ordered
  by URI then one-based line number, each excerpt contains the match and is
  at most 280 characters, and at most `limit` entries are returned.
  """
  @callback grep_content(String.t(), String.t() | nil, pos_integer()) ::
              {:ok, [line_match()]} | {:error, term()}

  @doc "Creates a session and returns its id."
  @callback create_session() :: {:ok, String.t()} | {:error, term()}

  @doc "Appends a message to a session, preserving order."
  @callback append_message(String.t(), atom(), String.t()) :: :ok | {:error, term()}

  @doc "Every message of a session, in order."
  @callback get_session(String.t()) :: {:ok, [message()]} | {:error, term()}

  @doc "Ids of every session, ordered, so an export can enumerate them."
  @callback list_session_ids() :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Restores a session with a specific id and its messages in order.

  Creates the session when absent and appends the messages. When the session
  already holds exactly these messages (compared as `{role, content}` pairs in
  order) it reports `{:ok, :skipped}` and writes nothing. When it holds
  different messages it reports `{:error, {:session_conflict, id}}` and leaves
  the stored session untouched, so an import never silently overwrites a live
  conversation.
  """
  @callback restore_session(String.t(), [message()]) ::
              {:ok, :imported | :skipped} | {:error, term()}

  @doc "The content hash recorded for a (session, destination) commit, if any."
  @callback commit_hash(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Writes the committed document and its commit bookkeeping together."
  @callback put_commit(String.t(), String.t(), String.t(), String.t()) ::
              {:ok, :ok} | {:error, term()}

  @doc "Writes a memory's document and its assertion together, so a URI never holds a document no assertion backs."
  @callback put_memory(String.t(), String.t(), float(), String.t() | nil) ::
              {:ok, :ok} | {:error, term()}

  @doc "Assertions at `prefix` or beneath it, most confident first."
  @callback recall_memories(String.t(), String.t() | nil, [:active | :superseded]) ::
              {:ok, [memory_row()]} | {:error, term()}

  @doc "Whether any assertion is recorded at `uri`, superseded ones included."
  @callback memory_recorded?(String.t()) :: {:ok, boolean()} | {:error, term()}

  @doc "Records durable background work."
  @callback enqueue_job(atom(), map()) :: {:ok, integer()} | {:error, term()}

  @doc "Drops queued work for `uri` or its descendants, in any state."
  @callback cancel_jobs(String.t()) :: :ok | {:error, term()}

  @doc "How many jobs target `uri` or its descendants and are in one of `statuses`."
  @callback count_jobs(String.t(), [String.t()]) :: non_neg_integer()

  @doc """
  Claims the next runnable job of one of `kinds`, advancing its attempt count.

  Filtered by kind so a worker never claims work it cannot run: a claimed job
  of another kind would be a job destroyed.
  """
  @callback dequeue_job([atom()]) :: {:ok, job()} | {:error, :empty} | {:error, term()}

  @doc "Marks a job done."
  @callback complete_job(integer()) :: :ok | {:error, term()}

  @doc """
  Records a job failure, rescheduling it with backoff while attempts remain and
  marking it failed once they are exhausted.
  """
  @callback fail_job(integer()) :: :ok | {:error, term()}

  @doc "Puts a job back without spending one of its attempts, for work that is merely waiting."
  @callback defer_job(integer(), non_neg_integer()) :: :ok | {:error, term()}

  @doc "Returns jobs left running by a previous run to pending."
  @callback reset_running_jobs() :: :ok | {:error, term()}

  @doc "Job counts by status."
  @callback queue_stats() :: {:ok, map()} | {:error, term()}

  @doc "Whether the durable state can be reached at all."
  @callback healthy?() :: boolean()
end
