defmodule AgentDb.Application.DataTransfer do
  @moduledoc false

  # Portable export/import of store data as a tar archive.
  #
  # An archive holds four JSON members at its root: a manifest plus the
  # documents, memories, and sessions it carries. Export walks the store
  # through the storage port and the application workflows' reads; import
  # validates the whole archive before writing anything, then restores
  # through the ordinary write paths so cache, jobs, and subscriptions
  # behave as they do for native writes.
  #
  # Derived data (embeddings, generated summaries, job queue, commit
  # bookkeeping) is not carried: it regenerates from the restored source
  # content through the existing background workers.

  alias AgentDb.Application.DataTransfer.Manifest
  alias AgentDb.Application.Documents
  alias AgentDb.Application.Memories
  alias AgentDb.Application.Sessions
  alias AgentDb.Archive
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @max_entries 10_000
  @max_bytes 50_000_000

  @memories_root "viking://user/memories"

  @type payload :: %{
          documents: [map()],
          memories: [map()],
          sessions: [map()],
          scope: String.t() | nil
        }

  @doc "The bounds one transfer accepts: entries, and expanded bytes."
  @spec limits() :: %{max_entries: pos_integer(), max_bytes: pos_integer()}
  def limits, do: %{max_entries: @max_entries, max_bytes: @max_bytes}

  @doc """
  Builds a tar archive binary from an export payload.

  The payload holds `documents` (`[%{uri, content, abstract, overview}]`),
  `memories` (`[%{uri, assertions: [%{value, confidence, source}]}]` oldest
  first), `sessions` (`[%{id, messages: [%{role, content}]}]` in order), and
  the `scope` the export covered (or `nil` for a full export). Returns the
  uncompressed tar binary; callers gzip it when the destination calls for it.
  """
  @spec export_payload(payload()) :: {:ok, binary()} | {:error, term()}
  def export_payload(%{documents: documents, memories: memories, sessions: sessions} = payload) do
    scope = Map.get(payload, :scope)

    with :ok <- Manifest.check_counts(documents, memories, sessions, limits()),
         {:ok, {docs_json, mems_json, sess_json}} <-
           Manifest.encode_payload(documents, memories, sessions),
         :ok <- Manifest.check_bytes(docs_json, mems_json, sess_json, limits()),
         {:ok, manifest_json} <-
           Manifest.encode(scope, documents, memories, sessions, docs_json, mems_json, sess_json),
         {:ok, archive} <-
           Archive.build(Manifest.members(manifest_json, docs_json, mems_json, sess_json)) do
      {:ok, archive}
    end
  end

  @doc """
  Reads and fully validates a transfer archive.

  Accepts `{:path, path}` or `{:archive, binary}`. Every refusal is about the
  whole archive and nothing is written by validation itself, so a caller that
  only writes after a successful parse leaves the store exactly as it was.
  Returns the decoded payload with its manifest.
  """
  @spec parse_archive({:path, Path.t()} | {:archive, binary()}) :: {:ok, map()} | {:error, term()}
  def parse_archive({:path, path}) when is_binary(path) do
    with {:ok, binary} <- read_file(path),
         :ok <- Manifest.check_size(byte_size(binary), limits()) do
      parse_archive({:archive, binary})
    end
  end

  def parse_archive({:archive, binary}) when is_binary(binary) do
    with :ok <- Manifest.check_size(byte_size(binary), limits()),
         {:ok, _listing} <- Archive.list(binary, @max_entries, @max_bytes),
         {:ok, extracted} <- Archive.extract(binary, @max_bytes),
         members = Map.to_list(extracted),
         :ok <- Manifest.check_members(members, limits()),
         {:ok, decoded} <- Manifest.decode(members),
         {:ok, payload} <- Manifest.validate_payload(decoded, limits()) do
      {:ok, payload}
    end
  end

  def parse_archive(_other), do: {:error, {:unreadable_source, :invalid, "(archive)"}}

  @doc """
  Exports store data to a tar file at `path`.

  Options: `:scope` - a `viking://` URI limiting documents and memories to
  that subtree (sessions are included only for a full export). A missing
  scope reports `:not_found` and writes no file. The archive is gzip
  compressed when the path ends in `.gz` or `.tgz`.
  """
  @spec export(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(path, opts \\ []) when is_binary(path) do
    scope = Keyword.get(opts, :scope)

    with {:ok, normalized_scope} <- normalize_scope(scope),
         {:ok, documents} <- collect_documents(normalized_scope),
         {:ok, memories} <- collect_memories(normalized_scope),
         {:ok, sessions} <- collect_sessions(normalized_scope),
         {:ok, {docs_json, mems_json, sess_json}} <-
           Manifest.encode_payload(documents, memories, sessions),
         {:ok, manifest_json} <-
           Manifest.encode(
             normalized_scope,
             documents,
             memories,
             sessions,
             docs_json,
             mems_json,
             sess_json
           ),
         :ok <-
           Archive.write(
             path,
             Manifest.members(manifest_json, docs_json, mems_json, sess_json),
             compressed?(path)
           ) do
      {:ok,
       %{
         path: path,
         scope: normalized_scope,
         documents: length(documents),
         memories: length(memories),
         sessions: length(sessions),
         messages: sessions |> Enum.map(&length(&1.messages)) |> Enum.sum()
       }}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Imports a transfer archive into the running store.

  Accepts a filesystem path or `{:archive, binary}`. The archive is validated
  whole before anything is written; a refused archive leaves the store exactly
  as it was. Import is additive-merge by URI: missing URIs are created,
  present ones are revised through the ordinary write paths, sessions with a
  colliding id and different messages are skipped, and nothing outside the
  archive is deleted.
  """
  @spec import(Path.t() | {:archive, binary()}) :: {:ok, map()} | {:error, term()}
  def import(source) do
    parsed =
      case source do
        {:archive, _} = archive -> parse_archive(archive)
        path when is_binary(path) -> parse_archive({:path, path})
        _other -> {:error, {:unreadable_source, :invalid, "(archive)"}}
      end

    with {:ok, payload} <- parsed do
      apply_payload(payload)
    end
  end

  # Whether an exported archive is gzipped is a property of where it is going,
  # which is what `export/2` documents: a destination named `.gz` or `.tgz` is
  # written compressed, and anything else is not. The reading side detects gzip
  # by its content, so a misnamed file is still read as what it is.
  defp compressed?(path) do
    String.ends_with?(path, ".gz") or String.ends_with?(path, ".tgz")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:unreadable_source, reason, path}}
    end
  end

  @doc """
  Why a transfer was refused or failed, as a sentence an operator can act on.
  """
  @spec message(term()) :: String.t()
  def message(:not_found), do: "the export scope does not exist"

  def message(:is_root),
    do: "the tree root cannot be exported as a scope; export without a scope instead"

  def message(:invalid_uri), do: "the scope is not a valid viking:// URI"
  def message({:invalid_scope, scope}), do: "#{inspect(scope)} is not a valid viking:// URI"
  def message({:no_such_scope, scope}), do: "#{scope} does not exist in the store"
  def message({:unreadable_source, _reason, path}), do: "#{path} could not be read"

  def message({:malformed_archive, reason}),
    do: "the archive could not be read: #{inspect(reason)}"

  def message({:too_many_entries, limit}), do: "the transfer holds more than #{limit} entries"
  def message({:too_large, limit}), do: "the transfer is larger than #{limit} bytes once expanded"
  def message({:missing_member, name}), do: "the archive is missing #{name}"
  def message({:unexpected_entry, name}), do: "the archive holds an unexpected entry: #{name}"

  def message({:unsupported_entry, type, name}),
    do: "the archive holds #{name}, which is a #{type} rather than a file or a directory"

  def message({:unsupported_entry, name}),
    do: "the archive holds #{name}, which is not a file or a directory"

  def message({:duplicate_entry, name}), do: "#{name} appears more than once in the archive"
  def message({:invalid_manifest, detail}), do: "the archive manifest is invalid: #{detail}"

  def message({:unsupported_version, version}),
    do: "archive format version #{version} is newer than supported (#{Manifest.format_version()})"

  def message({:checksum_mismatch, name}),
    do: "the archive checksum for #{name} does not match its content"

  def message({:count_mismatch, name}),
    do: "the archive manifest count for #{name} does not match its content"

  def message({:invalid_document, detail}), do: "the archive holds an invalid document: #{detail}"
  def message({:invalid_memory, detail}), do: "the archive holds an invalid memory: #{detail}"
  def message({:invalid_session, detail}), do: "the archive holds an invalid session: #{detail}"
  def message({:invalid_json, name}), do: "#{name} is not valid JSON"

  def message({:session_conflict, id}),
    do: "session #{id} already exists with different messages and was skipped"

  def message({:import_failed, failures}),
    do: "import failed for #{length(failures)} entries: #{inspect(Enum.take(failures, 3))}"

  def message(reason), do: inspect(reason)

  # -- export: collecting from the store --

  defp normalize_scope(nil), do: {:ok, nil}

  defp normalize_scope(scope) when is_binary(scope) do
    case VikingURI.parse(scope) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, segments} ->
        uri = VikingURI.build(segments)

        case Runtime.storage().get_node(uri) do
          {:ok, nil} -> {:error, {:no_such_scope, uri}}
          {:ok, _node} -> {:ok, uri}
          {:error, _} = err -> err
        end

      {:error, :invalid_uri} ->
        {:error, {:invalid_scope, scope}}
    end
  end

  defp normalize_scope(scope), do: {:error, {:invalid_scope, scope}}

  defp collect_documents(scope) do
    root = scope || "viking://"

    case walk(root, []) do
      {:ok, docs} -> {:ok, Enum.sort_by(docs, & &1.uri)}
      {:error, _} = err -> err
    end
  end

  defp walk(uri, acc) do
    case Runtime.storage().get_node(uri) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %{kind: :doc} = node} -> {:ok, [doc_entry(node) | acc]}
      {:ok, %{kind: :dir}} -> walk_children(uri, acc)
      {:error, _} = err -> err
    end
  end

  defp walk_children(uri, acc) do
    case Runtime.storage().list_children(uri) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, acc}, fn name, {:ok, acc} ->
          case child_uri(uri, name) do
            {:ok, child} ->
              case walk(child, acc) do
                {:ok, acc} -> {:cont, {:ok, acc}}
                {:error, _} = err -> {:halt, err}
              end

            {:error, _} = err ->
              {:halt, err}
          end
        end)

      {:error, :not_found} ->
        {:ok, acc}

      {:error, _} = err ->
        err
    end
  end

  defp child_uri("viking://", name) do
    case VikingURI.join([], name) do
      {:ok, segments} -> {:ok, VikingURI.build(segments)}
      {:error, _} = err -> err
    end
  end

  defp child_uri(uri, name) do
    case VikingURI.parse(uri) do
      {:ok, segments} ->
        case VikingURI.join(segments, name) do
          {:ok, joined} -> {:ok, VikingURI.build(joined)}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp doc_entry(node) do
    %{
      uri: node.uri,
      content: node.content || "",
      abstract: node.abstract,
      overview: node.overview
    }
  end

  defp collect_memories(scope) do
    prefix = memories_prefix(scope)

    case prefix do
      nil ->
        {:ok, []}

      prefix ->
        case Runtime.storage().recall_memories(prefix, nil, [:active, :superseded]) do
          {:ok, rows} -> {:ok, group_memories(rows)}
          {:error, _} = err -> err
        end
    end
  end

  defp memories_prefix(nil), do: @memories_root

  defp memories_prefix(scope) when is_binary(scope) do
    cond do
      scope == @memories_root -> @memories_root
      String.starts_with?(scope, @memories_root <> "/") -> scope
      String.starts_with?(@memories_root, scope <> "/") or scope == "viking://" -> @memories_root
      true -> nil
    end
  end

  defp group_memories(rows) do
    rows
    |> Enum.group_by(& &1.uri)
    |> Enum.map(fn {uri, assertions} ->
      ordered =
        assertions
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn row ->
          %{value: row.value, confidence: row.confidence * 1.0, source: row.source}
        end)

      %{uri: uri, assertions: ordered}
    end)
    |> Enum.sort_by(& &1.uri)
  end

  defp collect_sessions(nil) do
    with {:ok, ids} <- Sessions.list_ids() do
      Enum.reduce_while(Enum.sort(ids), {:ok, []}, fn id, {:ok, acc} ->
        case Sessions.get(id) do
          {:ok, messages} ->
            entry = %{
              id: id,
              messages: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})
            }

            {:cont, {:ok, [entry | acc]}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, sessions} -> {:ok, Enum.reverse(sessions)}
        {:error, _} = err -> err
      end
    end
  end

  defp collect_sessions(_scope), do: {:ok, []}

  defp apply_payload(%{documents: documents, memories: memories, sessions: sessions}) do
    memory_uris = MapSet.new(memories, & &1.uri)

    with {:ok, doc_count, doc_failures, written_uris} <- write_documents(documents, memory_uris),
         {:ok, mem_count, mem_failures, memory_uris_written} <- write_memories(memories),
         {:ok, sess_count, msg_count, skipped, sess_failures} <- write_sessions(sessions) do
      failures = doc_failures ++ mem_failures ++ sess_failures

      if failures == [] do
        {:ok,
         %{
           documents: doc_count,
           memories: mem_count,
           sessions: sess_count,
           messages: msg_count,
           skipped_sessions: skipped,
           uris: written_uris ++ memory_uris_written
         }}
      else
        {:error, {:import_failed, failures}}
      end
    end
  end

  defp write_documents(documents, memory_uris) do
    Enum.reduce(documents, {:ok, 0, [], []}, fn doc, {:ok, count, failures, uris} ->
      if MapSet.member?(memory_uris, doc.uri) do
        {:ok, count, failures, uris}
      else
        opts =
          [abstract: doc.abstract, overview: doc.overview]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        case Documents.write(doc.uri, doc.content, opts) do
          :ok -> {:ok, count + 1, failures, [doc.uri | uris]}
          {:error, reason} -> {:ok, count, [{doc.uri, reason} | failures], uris}
        end
      end
    end)
  end

  defp write_memories(memories) do
    Enum.reduce(memories, {:ok, 0, [], []}, fn memory, {:ok, count, failures, uris} ->
      if memory_converged?(memory) do
        {:ok, count + 1, failures, [memory.uri | uris]}
      else
        result =
          Enum.reduce_while(memory.assertions, :ok, fn assertion, :ok ->
            opts = [confidence: assertion.confidence] |> put_source(assertion.source)

            case Memories.remember(memory.uri, assertion.value, opts) do
              {:ok, _} -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        case result do
          :ok -> {:ok, count + 1, failures, [memory.uri | uris]}
          {:error, reason} -> {:ok, count, [{memory.uri, reason} | failures], uris}
        end
      end
    end)
  end

  # Re-importing an unchanged archive must not extend the supersession chain:
  # when the active assertion already equals the exported tip, there is
  # nothing to revise and the URI is left untouched.
  defp memory_converged?(%{uri: uri, assertions: assertions}) when is_list(assertions) do
    case {List.last(assertions), Memories.recall(uri)} do
      {nil, _} ->
        true

      {_, {:ok, []}} ->
        false

      {tip, {:ok, [active]}} ->
        active.value == tip.value and active.confidence == tip.confidence and
          active.source == tip.source

      _ ->
        false
    end
  end

  defp put_source(opts, nil), do: opts
  defp put_source(opts, source), do: Keyword.put(opts, :source, source)

  defp write_sessions(sessions) do
    Enum.reduce(sessions, {:ok, 0, 0, [], []}, fn session,
                                                  {:ok, sess_count, msg_count, skipped, failures} ->
      case Sessions.restore(session.id, session.messages) do
        {:ok, :imported} ->
          {:ok, sess_count + 1, msg_count + length(session.messages), skipped, failures}

        {:ok, :skipped} ->
          {:ok, sess_count + 1, msg_count + length(session.messages), [session.id | skipped],
           failures}

        {:error, {:session_conflict, _} = reason} ->
          {:ok, sess_count, msg_count, [session.id | skipped], [{session.id, reason} | failures]}

        {:error, reason} ->
          {:ok, sess_count, msg_count, skipped, [{session.id, reason} | failures]}
      end
    end)
    |> case do
      {:ok, sess_count, msg_count, skipped, []} ->
        {:ok, sess_count, msg_count, Enum.reverse(skipped), []}

      {:ok, sess_count, msg_count, skipped, failures} ->
        # Conflicts are skips, not failures: report them as skipped and succeed
        # unless a real storage error occurred.
        {conflicts, hard} =
          Enum.split_with(failures, fn {_id, reason} -> match?({:session_conflict, _}, reason) end)

        if hard == [] do
          {:ok, sess_count, msg_count, Enum.reverse(skipped), []}
        else
          {:ok, sess_count, msg_count, Enum.reverse(skipped) ++ Enum.map(conflicts, &elem(&1, 0)),
           hard}
        end
    end
  end
end
