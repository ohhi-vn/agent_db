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
  alias AgentDb.Subscriptions
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
  def write(uri, content, opts \\ []) do
    case Documents.write(uri, content, opts) do
      :ok ->
        notify(uri, :written)
        :ok

      {:error, _} = err ->
        err
    end
  end

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
  def rm(uri) do
    case Documents.rm(uri) do
      :ok ->
        notify(uri, :removed)
        :ok

      {:error, _} = err ->
        err
    end
  end

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

  @doc """
  Discovers files and directories whose URI path contains `query`.

  A literal, case-insensitive substring match over the URI path (excluding
  the `viking://` scheme). See `AgentDb.Application.Documents.find/2` for
  scoping, limits, ordering, and errors.
  """
  @spec find(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate find(query, opts \\ []), to: Documents

  @doc """
  Searches full document content (L2) for a literal substring.

  A literal, case-insensitive match that never looks at abstracts or
  overviews. See `AgentDb.Application.Search.grep/2` for scoping, limits,
  ordering, and errors.
  """
  @spec grep(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate grep(query, opts \\ []), to: Search

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
  def commit_session(session_id, destination_uri, opts \\ []) do
    case Sessions.commit(session_id, destination_uri, opts) do
      {:ok, dest} when is_binary(dest) ->
        notify(dest, :committed)
        {:ok, dest}

      other ->
        other
    end
  end

  # -- memory --

  @doc "Records a durable fact as a memory. See `AgentDb.Application.Memories.remember/3`."
  @spec remember(uri(), content(), keyword()) :: {:ok, uri()} | {:error, term()}
  def remember(uri, value, opts \\ []) do
    case Memories.remember(uri, value, opts) do
      {:ok, stored} ->
        notify(stored, :written)
        {:ok, stored}

      {:error, _} = err ->
        err
    end
  end

  @doc "Reads memories back. See `AgentDb.Application.Memories.recall/1`."
  @spec recall(uri() | keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate recall(uri_or_opts \\ []), to: Memories

  @doc "Removes a memory and its provenance. See `AgentDb.Application.Memories.forget/1`."
  @spec forget(uri()) :: :ok | {:error, term()}
  def forget(uri) do
    case Memories.forget(uri) do
      :ok ->
        notify(uri, :removed)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "The memory types, for callers that need to enumerate the taxonomy."
  @spec memory_types() :: [String.t()]
  defdelegate memory_types(), to: Memories, as: :types

  @doc "Subscribes the caller to changes beneath a `viking://` URI."
  @spec subscribe(uri()) :: :ok | {:error, term()}
  defdelegate subscribe(uri), to: Subscriptions

  @doc "Unsubscribes the caller from a `viking://` URI scope."
  @spec unsubscribe(uri()) :: :ok | {:error, term()}
  defdelegate unsubscribe(uri), to: Subscriptions

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
  def import_skills(user_id, source) do
    case Skills.import(user_id, source) do
      {:ok, %{skills: skills} = out} ->
        for %{status: status, name: name} when status in [:imported, :replaced] <- skills do
          notify("viking://user/#{user_id}/skills/#{name}", :replaced)
        end

        {:ok, out}

      {:error, _} = err ->
        err
    end
  end

  @doc "The bounds one skill import accepts, for a caller that has to bound its own input."
  @spec skill_import_limits() :: %{max_entries: pos_integer(), max_bytes: pos_integer()}
  defdelegate skill_import_limits(), to: Skills, as: :limits

  @doc "Why a skill import was refused, as a sentence an operator can act on."
  @spec skill_import_error_message(term()) :: String.t()
  defdelegate skill_import_error_message(reason), to: AgentDb.Skills.Source, as: :message

  @doc "The confidence recorded when a caller supplies none."
  @spec default_confidence() :: float()
  defdelegate default_confidence(), to: Memories

  # -- data portability --

  @doc """
  Exports store data to a tar archive at `path`.

  Snapshots documents (full content plus caller-supplied abstract/overview),
  memory provenance, and sessions into a single `.tar` or `.tar.gz` file that
  another store can import with `import_data/1`. With `scope:` the export is
  limited to one subtree (sessions are included only for a full export).

  Returns `{:ok, %{path:, scope:, documents:, memories:, sessions:, messages:}}`.
  """
  @spec export_data(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_data(path, opts \\ []) do
    AgentDb.Application.DataTransfer.export(path, opts)
  end

  @doc """
  Imports a transfer archive created by `export_data/1` into the running store.

  Accepts a filesystem path or `{:archive, binary}`. Validates the whole
  archive before writing anything; a refused archive leaves the store exactly
  as it was. Import merges by URI and never deletes content outside the
  archive. Re-importing an unchanged archive converges without duplication.
  """
  @spec import_data(Path.t() | {:archive, binary()}, keyword()) :: {:ok, map()} | {:error, term()}
  def import_data(source, _opts \\ []) do
    case AgentDb.Application.DataTransfer.import(source) do
      {:ok, %{uris: uris} = out} ->
        for uri <- uris, do: notify(uri, :written)

        {:ok, Map.delete(out, :uris)}

      {:error, _} = err ->
        err
    end
  end

  @doc "The bounds one data transfer accepts, for a caller that has to bound its own input."
  @spec data_transfer_limits() :: %{max_entries: pos_integer(), max_bytes: pos_integer()}
  defdelegate data_transfer_limits(), to: AgentDb.Application.DataTransfer, as: :limits

  @doc "Why a data export or import was refused, as a sentence an operator can act on."
  @spec export_data_error_message(term()) :: String.t()
  defdelegate export_data_error_message(reason), to: AgentDb.Application.DataTransfer, as: :message

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

  # Best-effort fan-out: a crashed or slow subscriber must never change the
  # write outcome.
  defp notify(uri, kind) do
    Subscriptions.broadcast(uri, kind)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
