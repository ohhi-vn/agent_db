defmodule AgentDb do
  @moduledoc """
  Embedded offline context store for AI agents (OpenViking-inspired).

  A URI-addressed tree with layered content (L0 abstract, L1 overview, L2 full
  content), keyword and vector search over it, append-only sessions that can be
  committed into the tree, and typed durable memories with their provenance.

  Every function here is a stable entry point. The work behind them belongs to
  the application workflows, which reach the store and the models through
  replaceable ports rather than naming either directly -- so what a caller
  depends on stays the same when what serves it changes.

  ## Starting

  ```elixir
  {:ok, _} = Application.ensure_all_started(:agent_db)
  :ok = AgentDb.write("viking://resources/readme.md", "# Title")
  {:ok, content} = AgentDb.read("viking://resources/readme.md")
  ```

  ## Layered content

  A document is stored with its full content and, optionally, a caller's own
  abstract and overview. A layer that was not supplied is generated in the
  background, and a read resolves to the first thing available: the stored
  layer, then the generated one, then a deterministic fallback that needs no
  model at all.
  """

  alias AgentDb.Application.{Documents, Memories, Search, Sessions, Skills, Status}
  alias AgentDb.URI, as: VikingURI

  @type uri :: String.t()
  @type content :: String.t()

  # -- tree operations --

  @doc """
  Writes a document at `uri`, creating missing parent directories.

  Persists and acknowledges before any embedding or summarization completes, so
  a read returns content immediately and searchability arrives progressively.
  With `async: false` the write waits instead, and reports whether the work
  completed, failed, or is still outstanding.

  Options:
    - `:async` - override `async_writes`
    - `:sync_timeout_ms` - how long a synchronous write waits (default 30_000)
    - `:abstract` / `:overview` - the caller's own L0 / L1 layers
  """
  @spec write(uri(), content(), keyword()) :: :ok | {:error, term()}
  defdelegate write(uri, content, opts \\ []), to: Documents

  @doc "Reads a document's full content (L2)."
  @spec read(uri()) :: {:ok, content()} | {:error, term()}
  defdelegate read(uri), to: Documents

  @doc "Reads a document's L0 abstract, falling back to the first non-empty line."
  @spec abstract(uri()) :: {:ok, content()} | {:error, term()}
  defdelegate abstract(uri), to: Documents

  @doc "Reads a document's L1 overview, falling back to the first 280 characters."
  @spec overview(uri()) :: {:ok, content()} | {:error, term()}
  defdelegate overview(uri), to: Documents

  @doc "Lists the names of a URI's direct children."
  @spec list(uri()) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list(uri), to: Documents

  @doc "A depth-limited projection of the tree at `uri` (default depth 2)."
  @spec tree(uri(), pos_integer()) :: {:ok, map()} | {:error, term()}
  defdelegate tree(uri, depth \\ 2), to: Documents

  @doc "Removes the subtree at `uri`, from every store keyed by URI."
  @spec rm(uri()) :: :ok | {:error, term()}
  defdelegate rm(uri), to: Documents

  # -- search --

  @doc """
  Searches documents by `:keyword`, `:vector`, or `:hybrid` (default
  `:keyword`).

  Options:
    - `:mode` - `:keyword`, `:vector`, or `:hybrid`
    - `:scope` - a URI prefix to limit the search to one subtree
    - `:top_k` - maximum results (default 10)
    - `:hybrid_weights` - `{keyword_weight, vector_weight}` (default `{0.5, 0.5}`)
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate search(term, opts \\ []), to: Search

  # -- sessions --

  @doc "Creates a session and returns its id."
  @spec create_session() :: {:ok, String.t()} | {:error, term()}
  defdelegate create_session(), to: Sessions, as: :create

  @doc "Appends a message to a session (role: `:user` | `:assistant` | `:system`)."
  @spec append_message(String.t(), atom(), String.t()) :: :ok | {:error, term()}
  defdelegate append_message(session_id, role, content), to: Sessions

  @doc "Returns every message of a session, in order."
  @spec get_session(String.t()) :: {:ok, [map()]} | {:error, term()}
  defdelegate get_session(session_id), to: Sessions, as: :get

  @doc """
  Commits a session into the tree at `destination_uri` as one document.

  Idempotent per (session, destination): re-committing an unchanged session
  returns `{:ok, :unchanged}`. If the destination has since been removed, the
  commit rebuilds it rather than reporting it unchanged.
  """
  @spec commit_session(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | :unchanged} | {:error, term()}
  defdelegate commit_session(session_id, destination_uri, opts \\ []), to: Sessions, as: :commit

  # -- memory --

  @doc "Records a durable fact as a memory. See `AgentDb.Application.Memories.remember/3`."
  @spec remember(uri(), content(), keyword()) :: {:ok, uri()} | {:error, term()}
  defdelegate remember(uri, value, opts \\ []), to: Memories

  @doc "Reads memories back. See `AgentDb.Application.Memories.recall/1`."
  @spec recall(uri() | keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate recall(uri_or_opts \\ []), to: Memories

  @doc "Removes a memory and its provenance. See `AgentDb.Application.Memories.forget/1`."
  @spec forget(uri()) :: :ok | {:error, term()}
  defdelegate forget(uri), to: Memories

  @doc "The memory types, for callers that need to enumerate the taxonomy."
  @spec memory_types() :: [String.t()]
  defdelegate memory_types(), to: Memories, as: :types

  # -- skills --

  @doc """
  Imports Agent Skills into `viking://user/{user_id}/skills`.

  A source is a folder, a tar archive (gzip-compressed or not), or the files of a
  browser directory selection:

      AgentDb.import_skills("alice", {:path, "./my-skills"})
      AgentDb.import_skills("alice", {:path, "./my-skills.tar.gz"})
      AgentDb.import_skills("alice", {:uploads, [%{path: "alpha/SKILL.md", content: body}]})

  Each skill is a directory with a `SKILL.md` at its root, and a source may hold
  one skill or a collection of them; a skill's name is its directory's name. See
  `AgentDb.Skills.Source` for what is accepted and what is refused.

  A skill stored under that name already is replaced whole -- files the new
  source does not have go with it -- and a replacement that fails leaves the
  stored skill as it was, so a valid skill in the same source still lands.

  Answers the outcome of every skill, or one error for the source as a whole.
  Nothing is written until the whole source has been accepted, so an error leaves
  the store as it was. `AgentDb.skills_import_error_message/1` turns the error
  into a sentence.
  """
  @spec import_skills(String.t(), AgentDb.Application.Skills.source()) ::
          {:ok, %{skills: [AgentDb.Application.Skills.result()]}} | {:error, term()}
  defdelegate import_skills(user_id, source), to: Skills, as: :import

  @doc "The bounds one skill import accepts, for a caller that has to bound its own input."
  @spec skill_import_limits() :: %{max_entries: pos_integer(), max_bytes: pos_integer()}
  defdelegate skill_import_limits(), to: Skills, as: :limits

  @doc "Why a skill import was refused, as a sentence an operator can act on."
  @spec skill_import_error_message(term()) :: String.t()
  defdelegate skill_import_error_message(reason), to: AgentDb.Skills.Source, as: :message

  @doc "The confidence recorded when a caller supplies none."
  @spec default_confidence() :: float()
  defdelegate default_confidence(), to: Memories

  # -- status --

  @doc "How the store's models are doing, including a load in progress."
  @spec model_status() :: map()
  defdelegate model_status(), to: Status, as: :models

  @doc "Whether the store and its models are usable, checked individually."
  @spec health_check() :: %{status: String.t(), checks: %{db: boolean(), models: boolean()}}
  defdelegate health_check(), to: Status, as: :health

  @doc "How much background work is outstanding, by status."
  @spec queue_stats() :: map()
  defdelegate queue_stats(), to: Status, as: :queue

  # -- validation, for callers that check a URI before using it --

  @doc "The segments of a `viking://` URI, or `{:error, :invalid_uri}`."
  @spec parse_uri(uri()) :: {:ok, [String.t()]} | {:error, term()}
  def parse_uri(uri), do: VikingURI.parse(uri)
end
