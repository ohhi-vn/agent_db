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

  @doc "Reads a document's L0 abstract, falling back to frontmatter identity or the first non-empty body line."
  @spec abstract(uri()) :: {:ok, content()} | {:error, term()}
  defdelegate abstract(uri), to: Documents

  @doc "Reads a document's L1 overview, falling back to the first 280 characters of the body after frontmatter."
  @spec overview(uri()) :: {:ok, content()} | {:error, term()}
  defdelegate overview(uri), to: Documents

  @doc "Reads a document's stored L0/L1 layers without fallback."
  @spec stored_layers(uri()) ::
          {:ok, %{abstract: content() | nil, overview: content() | nil}} | {:error, term()}
  defdelegate stored_layers(uri), to: Documents

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
    - `:hybrid_weights` - `{keyword_weight, vector_weight}` or `[keyword: kw, vector: vw]` (default `{0.5, 0.5}`)
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate search(term, opts \\ []), to: Search

  @doc """
  Discovers files and directories whose URI path contains `query`.

  A literal, case-insensitive substring match over the URI path (excluding
  the `viking://` scheme). See AgentDb.Application.Documents.find/2 for
  scoping, limits, ordering, and errors.
  """
  @spec find(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate find(query, opts \\ []), to: Documents

  @doc """
  Searches full document content (L2) for a literal substring.

  A literal, case-insensitive match that never looks at abstracts or
  overviews. See AgentDb.Application.Search.grep/2 for scoping, limits,
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

  @doc "Records a durable fact as a memory. See AgentDb.Application.Memories.remember/3."
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

  @doc "Reads memories back. See AgentDb.Application.Memories.recall/1."
  @spec recall(uri() | keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate recall(uri_or_opts \\ []), to: Memories

  @doc "Removes a memory and its provenance. See AgentDb.Application.Memories.forget/1."
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

  @doc "Promotes the waiting candidate at `uri` to the active memory."
  @spec promote_memory(uri()) :: {:ok, uri()} | {:error, term()}
  def promote_memory(uri) do
    case Memories.promote(uri) do
      {:ok, stored} ->
        notify(stored, :written)
        {:ok, stored}

      {:error, _} = err ->
        err
    end
  end

  @doc "Rejects the waiting candidate at `uri`, leaving no trace of it."
  @spec reject_memory_candidate(uri()) :: :ok | {:error, term()}
  def reject_memory_candidate(uri) do
    case Memories.reject_candidate(uri) do
      :ok ->
        notify(uri, :removed)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Candidates waiting for promotion review. See AgentDb.Application.Memories.pending_candidates/1."
  @spec pending_memory_candidates(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate pending_memory_candidates(opts \\ []), to: Memories, as: :pending_candidates

  @doc "Possible conflicts between active memories. See AgentDb.Application.Memories.conflicts/1."
  @spec memory_conflicts(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate memory_conflicts(opts \\ []), to: Memories, as: :conflicts

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
  the store as it was. `AgentDb.skill_import_error_message/1` turns the error
  into a sentence.
  """
  @spec import_skills(String.t(), AgentDb.Skills.Source.source()) ::
          {:ok,
           %{
             skills: [
               %{
                 name: String.t(),
                 status: :imported | :replaced | :failed,
                 files: non_neg_integer(),
                 reason: term() | nil
               }
             ]
           }}
          | {:error, term()}
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

  # -- node management (enable/disable, grouping, operations listings) --

  @doc """
  Enables or disables the subtree at `uri`.

  Disabled is blocked-from-use: excluded from search and default listings,
  but still readable and editable. Notifies subscribers so the console
  reloads without restart.
  """
  @spec set_enabled(uri(), boolean()) :: :ok | {:error, term()}
  def set_enabled(uri, enabled) when is_boolean(enabled) do
    case AgentDb.Runtime.storage().set_node_enabled(uri, enabled) do
      :ok ->
        AgentDb.Cache.invalidate_removal(uri)
        notify(uri, :replaced)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Assigns the operator group tag for the subtree at `uri`. Empty clears.
  """
  @spec set_group(uri(), String.t()) :: :ok | {:error, term()}
  def set_group(uri, tag) when is_binary(tag) do
    case AgentDb.Runtime.storage().set_node_group(uri, tag) do
      :ok ->
        AgentDb.Cache.invalidate_removal(uri)
        notify(uri, :replaced)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Applies `set_enabled` to every URI in `uris`, attempting each one.
  Answers per-URI outcomes plus summary counts.
  """
  @spec bulk_set_enabled([uri()], boolean()) ::
          {:ok, %{results: [map()], updated: non_neg_integer(), failed: non_neg_integer()}}
  def bulk_set_enabled(uris, enabled) when is_list(uris) and is_boolean(enabled) do
    results =
      Enum.map(uris, fn uri ->
        case set_enabled(uri, enabled) do
          :ok -> %{uri: uri, status: :ok, reason: nil}
          {:error, reason} -> %{uri: uri, status: :failed, reason: reason}
        end
      end)

    {:ok,
     %{
       results: results,
       updated: Enum.count(results, &(&1.status == :ok)),
       failed: Enum.count(results, &(&1.status == :failed))
     }}
  end

  @doc """
  Applies `set_group` to every URI in `uris`, attempting each one.
  """
  @spec bulk_set_group([uri()], String.t()) ::
          {:ok, %{results: [map()], updated: non_neg_integer(), failed: non_neg_integer()}}
  def bulk_set_group(uris, tag) when is_list(uris) and is_binary(tag) do
    results =
      Enum.map(uris, fn uri ->
        case set_group(uri, tag) do
          :ok -> %{uri: uri, status: :ok, reason: nil}
          {:error, reason} -> %{uri: uri, status: :failed, reason: reason}
        end
      end)

    {:ok,
     %{
       results: results,
       updated: Enum.count(results, &(&1.status == :ok)),
       failed: Enum.count(results, &(&1.status == :failed))
     }}
  end

  @default_list_page 1
  @default_list_per_page 50
  @max_list_per_page 200

  @doc """
  Recursive document URIs under `scope` in deterministic order, paged.

  Options: `:page` (default 1), `:per_page` (default 50, max 200),
  `:substring`, `:include_disabled` (default false), `:group`.
  """
  @spec list_all_documents(uri(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_all_documents(scope \\ "viking://", opts \\ []) do
    with {:ok, _} <- AgentDb.URI.parse(scope) do
      page = clamp_page(Keyword.get(opts, :page, @default_list_page))
      per_page = clamp_per_page(Keyword.get(opts, :per_page, @default_list_per_page))

      filter = %{
        substring: Keyword.get(opts, :substring, ""),
        include_disabled: Keyword.get(opts, :include_disabled, false),
        group: Keyword.get(opts, :group, "")
      }

      fetch_all_documents(scope, filter, page, per_page)
    end
  end

  @doc """
  Installed skill roots in URI order, paged. Each entry carries `name`,
  `owner`, `uri`, `files`, `enabled`, and `group_tag`.

  Options: `:page`, `:per_page`, `:substring`, `:owner`, `:include_disabled`,
  `:group`.
  """
  @spec list_skills(keyword()) :: {:ok, map()} | {:error, term()}
  def list_skills(opts \\ []) do
    page = clamp_page(Keyword.get(opts, :page, @default_list_page))
    per_page = clamp_per_page(Keyword.get(opts, :per_page, @default_list_per_page))

    filter = %{
      substring: Keyword.get(opts, :substring, ""),
      owner: Keyword.get(opts, :owner, ""),
      include_disabled: Keyword.get(opts, :include_disabled, false),
      group: Keyword.get(opts, :group, "")
    }

    fetch_skills(filter, page, per_page)
  end

  defp clamp_page(page) when is_integer(page) and page >= 1, do: page
  defp clamp_page(_), do: @default_list_page

  defp clamp_per_page(per_page)
       when is_integer(per_page) and per_page >= 1 and per_page <= @max_list_per_page,
       do: per_page

  defp clamp_per_page(_), do: @default_list_per_page

  defp page_of_all(rows, total, page, per_page) do
    total_pages = max(div(total + per_page - 1, per_page), 1)
    page = page |> max(1) |> min(total_pages)

    %{data: rows, meta: %{page: page, per_page: per_page, total: total, total_pages: total_pages}}
  end

  defp fetch_all_documents(scope, filter, page, per_page) do
    offset = (page - 1) * per_page

    case AgentDb.Runtime.storage().list_all_documents(scope, per_page, offset, filter) do
      {:ok, {rows, total}} ->
        total_pages = max(div(total + per_page - 1, per_page), 1)
        clamped = page |> max(1) |> min(total_pages)

        if clamped == page do
          {:ok, page_of_all(rows, total, page, per_page)}
        else
          case AgentDb.Runtime.storage().list_all_documents(
                 scope,
                 per_page,
                 (clamped - 1) * per_page,
                 filter
               ) do
            {:ok, {rows2, _}} -> {:ok, page_of_all(rows2, total, clamped, per_page)}
            {:error, _} = err -> err
          end
        end

      {:error, _} = err ->
        err
    end
  end

  defp fetch_skills(filter, page, per_page) do
    offset = (page - 1) * per_page

    case AgentDb.Runtime.storage().list_skill_roots(per_page, offset, filter) do
      {:ok, {rows, total}} ->
        total_pages = max(div(total + per_page - 1, per_page), 1)
        clamped = page |> max(1) |> min(total_pages)

        if clamped == page do
          {:ok, page_of_all(rows, total, page, per_page)}
        else
          case AgentDb.Runtime.storage().list_skill_roots(
                 per_page,
                 (clamped - 1) * per_page,
                 filter
               ) do
            {:ok, {rows2, _}} -> {:ok, page_of_all(rows2, total, clamped, per_page)}
            {:error, _} = err -> err
          end
        end

      {:error, _} = err ->
        err
    end
  end

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
  defdelegate export_data_error_message(reason),
    to: AgentDb.Application.DataTransfer,
    as: :message

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

  @doc """
  How far behind the queue is, and which jobs are failing.

  Beyond `queue_stats/0`'s counts: the age of the longest-waiting pending job,
  and the failures that spent their retries, each with the classified reason.
  """
  @spec queue_detail(pos_integer()) :: map()
  defdelegate queue_detail(limit \\ 20), to: Status, as: :queue_detail

  @doc """
  What the store holds and how much room it takes on disk.

  Document and directory counts, documents per top-level subtree, and the
  database and write-ahead-log sizes.
  """
  @spec storage_stats() :: map()
  defdelegate storage_stats(), to: Status, as: :storage

  @doc """
  The size of the store's disposable read caches: entries and bytes per table.
  """
  @spec cache_stats() :: map()
  defdelegate cache_stats(), to: Status, as: :cache

  @doc """
  How much of the store's content each index covers.

  Vector index availability and row count against the document count, plus the
  documents under each index's own roots. An index that cannot be queried
  reports unavailable rather than reporting zero. The vector leg additionally
  reports `active_dim` and `needs_backfill` when the provider serves them.
  """
  @spec index_coverage() :: map()
  def index_coverage do
    Status.index_coverage()
    |> Map.merge(%{
      code_documents: AgentDb.CodeIndex.coverage().documents,
      hex_documents: AgentDb.HexDocs.coverage().documents,
      hex_packages: AgentDb.HexDocs.coverage().packages
    })
  end

  @doc """
  Drops a non-active vector dim table (`vec_nodes_<dim>`).

  Refuses the active dim; boot never wipes. An operator action for reclaiming
  disk after a provider switch, not part of any write path.
  """
  @spec prune_vector_index(pos_integer()) :: :ok | {:error, term()}
  def prune_vector_index(dim) do
    storage = AgentDb.Runtime.storage()

    if function_exported?(storage, :prune_vector_index, 1) do
      storage.prune_vector_index(dim)
    else
      {:error, :unsupported}
    end
  end

  @doc """
  Enqueues `:embed` jobs only for URIs missing in the active dim table.

  Switching providers creates the new table if missing and backfills the diff;
  URIs already covered are never re-enqueued.
  """
  @spec backfill_vector_index() :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill_vector_index do
    storage = AgentDb.Runtime.storage()

    if function_exported?(storage, :backfill_vector_index, 0) do
      storage.backfill_vector_index()
    else
      {:error, :unsupported}
    end
  end

  @doc """
  A bounded, read-only view of the BEAM runtime: uptime, applications,
  supervisors, process counts, ETS tables, memory, and scheduler figures.

  Read-only by construction: nothing is started, stopped, or messaged to take
  one. Never writes, so a snapshot is safe to take at any time.
  """
  @spec runtime_snapshot() :: {:ok, map()} | {:error, term()}
  defdelegate runtime_snapshot(), to: AgentDb.RuntimeContext, as: :snapshot

  @doc """
  Recent operational failures, newest first, with the operation they happened in
  and their classified reason. Bounded and in memory only.
  """
  @spec recent_errors(pos_integer()) :: [map()]
  def recent_errors(limit \\ 20), do: AgentDb.Observability.recent_errors(limit)

  @doc "Operation, job, and model counts by outcome since this process started."
  @spec operation_stats() :: map()
  defdelegate operation_stats(), to: AgentDb.Observability, as: :operation_stats

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
