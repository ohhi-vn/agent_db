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

  alias AgentDb.Application.{Documents, Memories, Sessions}
  alias AgentDb.Runtime
  alias AgentDb.URI, as: VikingURI

  @format_version 1

  @manifest_name "manifest.json"
  @documents_name "documents.json"
  @memories_name "memories.json"
  @sessions_name "sessions.json"
  @expected_members [@manifest_name, @documents_name, @memories_name, @sessions_name]

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

    with :ok <- check_counts(documents, memories, sessions),
         {:ok, {docs_json, mems_json, sess_json}} <- encode_payload(documents, memories, sessions),
         :ok <- check_bytes(docs_json, mems_json, sess_json),
         {:ok, manifest_json} <-
           encode_manifest(scope, documents, memories, sessions, docs_json, mems_json, sess_json),
         {:ok, archive} <-
           build_tar([
             {@manifest_name, manifest_json},
             {@documents_name, docs_json},
             {@memories_name, mems_json},
             {@sessions_name, sess_json}
           ]) do
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
         :ok <- check_size(byte_size(binary)) do
      parse_archive({:archive, binary})
    end
  end

  def parse_archive({:archive, binary}) when is_binary(binary) do
    with :ok <- check_size(byte_size(binary)),
         {:ok, tar} <- plain_tar(binary),
         {:ok, rows} <- table(tar),
         :ok <- check_count(length(rows)),
         :ok <- check_size(declared_size(rows)),
         {:ok, members} <- extract(tar),
         :ok <- check_members(members),
         {:ok, decoded} <- decode_members(members),
         {:ok, payload} <- validate_payload(decoded) do
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
         {:ok, {docs_json, mems_json, sess_json}} <- encode_payload(documents, memories, sessions),
         {:ok, manifest_json} <-
           encode_manifest(normalized_scope, documents, memories, sessions, docs_json, mems_json, sess_json),
         :ok <- write_tar(path, manifest_json, docs_json, mems_json, sess_json) do
      {:ok,
       %{
         path: path,
         scope: normalized_scope,
         documents: length(documents),
         memories: length(memories),
         sessions: length(sessions),
         messages: sessions |> Enum.map(&(length(&1.messages))) |> Enum.sum()
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

  @doc """
  Why a transfer was refused or failed, as a sentence an operator can act on.
  """
  @spec message(term()) :: String.t()
  def message(:not_found), do: "the export scope does not exist"
  def message(:is_root), do: "the tree root cannot be exported as a scope; export without a scope instead"
  def message(:invalid_uri), do: "the scope is not a valid viking:// URI"
  def message({:invalid_scope, scope}), do: "#{inspect(scope)} is not a valid viking:// URI"
  def message({:no_such_scope, scope}), do: "#{scope} does not exist in the store"
  def message({:unreadable_source, _reason, path}), do: "#{path} could not be read"
  def message({:malformed_archive, reason}), do: "the archive could not be read: #{inspect(reason)}"
  def message({:too_many_entries, limit}), do: "the transfer holds more than #{limit} entries"
  def message({:too_large, limit}), do: "the transfer is larger than #{limit} bytes once expanded"
  def message({:missing_member, name}), do: "the archive is missing #{name}"
  def message({:unexpected_entry, name}), do: "the archive holds an unexpected entry: #{name}"
  def message({:duplicate_entry, name}), do: "#{name} appears more than once in the archive"
  def message({:invalid_manifest, detail}), do: "the archive manifest is invalid: #{detail}"
  def message({:unsupported_version, version}), do: "archive format version #{version} is newer than supported (#{@format_version})"
  def message({:checksum_mismatch, name}), do: "the archive checksum for #{name} does not match its content"
  def message({:count_mismatch, name}), do: "the archive manifest count for #{name} does not match its content"
  def message({:invalid_document, detail}), do: "the archive holds an invalid document: #{detail}"
  def message({:invalid_memory, detail}), do: "the archive holds an invalid memory: #{detail}"
  def message({:invalid_session, detail}), do: "the archive holds an invalid session: #{detail}"
  def message({:invalid_json, name}), do: "#{name} is not valid JSON"
  def message({:session_conflict, id}), do: "session #{id} already exists with different messages and was skipped"
  def message({:import_failed, failures}), do: "import failed for #{length(failures)} entries: #{inspect(Enum.take(failures, 3))}"
  def message(reason), do: inspect(reason)

  # -- export: collecting from the store --

  defp normalize_scope(nil), do: {:ok, nil}

  defp normalize_scope(scope) when is_binary(scope) do
    case VikingURI.parse(scope) do
      {:ok, []} -> {:ok, nil}
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
    %{uri: node.uri, content: node.content || "", abstract: node.abstract, overview: node.overview}
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
        |> Enum.map(fn row -> %{value: row.value, confidence: row.confidence * 1.0, source: row.source} end)

      %{uri: uri, assertions: ordered}
    end)
    |> Enum.sort_by(& &1.uri)
  end

  defp collect_sessions(nil) do
    with {:ok, ids} <- Sessions.list_ids() do
      Enum.reduce_while(Enum.sort(ids), {:ok, []}, fn id, {:ok, acc} ->
        case Sessions.get(id) do
          {:ok, messages} ->
            entry = %{id: id, messages: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})}
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

  # -- export: encoding --

  defp encode_payload(documents, memories, sessions) do
    with {:ok, docs_json} <- encode_json(documents),
         {:ok, mems_json} <- encode_json(memories),
         {:ok, sess_json} <- encode_json(sessions) do
      {:ok, {docs_json, mems_json, sess_json}}
    end
  end

  defp encode_json(term) do
    {:ok, Jason.encode!(term)}
  rescue
    e -> {:error, {:invalid_json, inspect(e)}}
  end

  defp encode_manifest(scope, documents, memories, sessions, docs_json, mems_json, sess_json) do
    message_count = sessions |> Enum.map(&(length(&1.messages))) |> Enum.sum()

    manifest = %{
      format_version: @format_version,
      scope: scope,
      exported_at: System.system_time(:millisecond),
      counts: %{
        documents: length(documents),
        memories: length(memories),
        sessions: length(sessions),
        messages: message_count
      },
      checksums: %{
        documents: sha256(docs_json),
        memories: sha256(mems_json),
        sessions: sha256(sess_json)
      }
    }

    case Jason.encode(manifest) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_manifest, inspect(reason)}}
    end
  end

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp check_counts(documents, memories, sessions) do
    assertions = memories |> Enum.map(&(length(&1.assertions))) |> Enum.sum()
    messages = sessions |> Enum.map(&(length(&1.messages))) |> Enum.sum()
    total = length(documents) + assertions + messages

    if total > @max_entries, do: {:error, {:too_many_entries, @max_entries}}, else: :ok
  end

  defp check_bytes(docs_json, mems_json, sess_json) do
    total = byte_size(docs_json) + byte_size(mems_json) + byte_size(sess_json)

    if total > @max_bytes, do: {:error, {:too_large, @max_bytes}}, else: :ok
  end

  defp build_tar(members) do
    path = Path.join(System.tmp_dir!(), "agent_db_export_#{System.unique_integer([:positive])}.tar")

    charlists = Enum.map(members, fn {name, content} -> {String.to_charlist(name), content} end)

    try do
      case :erl_tar.create(String.to_charlist(path), charlists, []) do
        :ok ->
          case File.read(path) do
            {:ok, binary} -> {:ok, binary}
            {:error, reason} -> {:error, {:unreadable_source, reason, path}}
          end

        {:error, reason} ->
          {:error, {:malformed_archive, reason}}
      end
    after
      File.rm(path)
    end
  end

  defp write_tar(path, manifest_json, docs_json, mems_json, sess_json) do
    :ok = File.mkdir_p(Path.dirname(path))
    compressed = String.ends_with?(path, ".gz") or String.ends_with?(path, ".tgz")
    opts = if compressed, do: [:compressed], else: []

    members = [
      {String.to_charlist(@manifest_name), manifest_json},
      {String.to_charlist(@documents_name), docs_json},
      {String.to_charlist(@memories_name), mems_json},
      {String.to_charlist(@sessions_name), sess_json}
    ]

    case :erl_tar.create(String.to_charlist(path), members, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unreadable_source, reason, path}}
    end
  end

  # -- import: reading an archive --

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:unreadable_source, reason, path}}
    end
  end

  defp plain_tar(<<0x1F, 0x8B, _rest::binary>> = binary), do: inflate(binary)
  defp plain_tar(binary), do: {:ok, binary}

  defp inflate(binary) do
    zlib = :zlib.open()

    try do
      :zlib.inflateInit(zlib, 31)
      inflate_loop(zlib, binary, 0, [])
    catch
      _kind, reason -> {:error, {:malformed_archive, reason}}
    after
      :zlib.close(zlib)
    end
  end

  defp inflate_loop(zlib, input, total, acc) do
    case :zlib.safeInflate(zlib, input) do
      {:finished, output} -> assemble(total + :erlang.iolist_size(output), [acc | output])
      {:continue, output} -> expand(zlib, total + :erlang.iolist_size(output), [acc | output])
      {:need_dictionary, _adler, _output} -> {:error, {:malformed_archive, :needs_dictionary}}
    end
  end

  defp expand(_zlib, total, _acc) when total > @max_bytes, do: {:error, {:too_large, @max_bytes}}
  defp expand(zlib, total, acc), do: inflate_loop(zlib, [], total, acc)

  defp assemble(total, _acc) when total > @max_bytes, do: {:error, {:too_large, @max_bytes}}
  defp assemble(_total, acc), do: {:ok, :erlang.iolist_to_binary(acc)}

  defp table(tar) do
    case :erl_tar.table({:binary, tar}, [:verbose]) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:malformed_archive, reason}}
    end
  end

  defp declared_size(rows) do
    sizes = for {_name, type, size, _mtime, _mode, _uid, _gid} <- rows, type == :regular, do: size
    Enum.sum(sizes)
  end

  defp extract(tar) do
    case :erl_tar.extract({:binary, tar}, [:memory, {:max_size, @max_bytes}]) do
      {:ok, members} -> {:ok, members}
      {:error, :too_big} -> {:error, {:too_large, @max_bytes}}
      {:error, reason} -> {:error, {:malformed_archive, reason}}
    end
  end

  defp check_members(members) do
    names = Enum.map(members, fn {name, _content} -> List.to_string(name) end)

    with :ok <- check_count(length(members)),
         :ok <- check_duplicates(names),
         :ok <- check_expected(names),
         :ok <- check_names_safe(names) do
      :ok
    end
  end

  defp check_count(count) when count > @max_entries, do: {:error, {:too_many_entries, @max_entries}}
  defp check_count(_), do: :ok

  defp check_size(bytes) when bytes > @max_bytes, do: {:error, {:too_large, @max_bytes}}
  defp check_size(_), do: :ok

  defp check_duplicates(names) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_entry, dup}}
    end
  end

  defp check_expected(names) do
    with :ok <- check_present(names) do
      case Enum.find(names, &(&1 not in @expected_members)) do
        nil -> :ok
        extra -> {:error, {:unexpected_entry, extra}}
      end
    end
  end

  defp check_present(names) do
    case Enum.find(@expected_members, &(&1 not in names)) do
      nil -> :ok
      missing -> {:error, {:missing_member, missing}}
    end
  end

  defp check_names_safe(names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      if safe_member_name?(name), do: {:cont, :ok}, else: {:halt, {:error, {:unexpected_entry, name}}}
    end)
  end

  defp safe_member_name?(name) do
    not String.starts_with?(name, "/") and ".." not in String.split(name, "/") and
      not String.contains?(name, "\\") and String.valid?(name)
  end

  defp decode_members(members) do
    by_name = Map.new(members, fn {name, content} -> {List.to_string(name), content} end)

    with {:ok, manifest} <- decode_json(by_name[@manifest_name], @manifest_name),
         {:ok, documents} <- decode_json(by_name[@documents_name], @documents_name),
         {:ok, memories} <- decode_json(by_name[@memories_name], @memories_name),
         {:ok, sessions} <- decode_json(by_name[@sessions_name], @sessions_name) do
      {:ok,
       %{
         manifest: manifest,
         documents: documents,
         memories: memories,
         sessions: sessions,
         raw: %{
           @documents_name => by_name[@documents_name],
           @memories_name => by_name[@memories_name],
           @sessions_name => by_name[@sessions_name]
         }
       }}
    end
  end

  defp decode_json(binary, name) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, {:invalid_json, name}}
    end
  end

  defp decode_json(_other, name), do: {:error, {:invalid_json, name}}

  defp validate_payload(%{manifest: manifest, documents: documents, memories: memories, sessions: sessions, raw: raw}) do
    with :ok <- validate_manifest(manifest, documents, memories, sessions, raw),
         {:ok, documents} <- validate_documents(documents),
         {:ok, memories} <- validate_memories(memories),
         {:ok, sessions} <- validate_sessions(sessions),
         :ok <- check_transfer_counts(documents, memories, sessions) do
      {:ok, %{manifest: manifest, documents: documents, memories: memories, sessions: sessions}}
    end
  end

  defp validate_manifest(manifest, documents, memories, sessions, raw) when is_map(manifest) do
    with {:ok, version} <- fetch_version(manifest),
         :ok <- check_version(version),
         :ok <- check_counts_match(manifest, documents, memories, sessions),
         :ok <- check_checksums(manifest, raw) do
      :ok
    end
  end

  defp validate_manifest(_other, _d, _m, _s, _r), do: {:error, {:invalid_manifest, "manifest must be an object"}}

  defp fetch_version(%{"format_version" => version}) when is_integer(version), do: {:ok, version}
  defp fetch_version(_), do: {:error, {:invalid_manifest, "missing format_version"}}

  defp check_version(@format_version), do: :ok
  defp check_version(version) when is_integer(version) and version > @format_version, do: {:error, {:unsupported_version, version}}
  defp check_version(version), do: {:error, {:invalid_manifest, "bad format_version #{inspect(version)}"}}

  defp check_counts_match(%{"counts" => counts}, documents, memories, sessions)
       when is_map(counts) and is_list(documents) and is_list(memories) and is_list(sessions) do
    message_count = sessions |> Enum.map(&(length Map.get(&1, "messages", []))) |> Enum.sum()

    expected = %{
      "documents" => length(documents),
      "memories" => length(memories),
      "sessions" => length(sessions),
      "messages" => message_count
    }

    mismatch = Enum.find(expected, fn {key, count} -> Map.get(counts, key) != count end)

    case mismatch do
      nil -> :ok
      {key, _} -> {:error, {:count_mismatch, key}}
    end
  end

  defp check_counts_match(_manifest, _d, _m, _s), do: {:error, {:invalid_manifest, "missing counts"}}

  defp check_checksums(%{"checksums" => checksums}, raw) when is_map(checksums) do
    Enum.reduce_while(@expected_members -- [@manifest_name], :ok, fn name, :ok ->
      expected = Map.get(checksums, String.trim_trailing(name, ".json"))

      if expected == sha256(raw[name]) do
        {:cont, :ok}
      else
        {:halt, {:error, {:checksum_mismatch, name}}}
      end
    end)
  end

  defp check_checksums(_manifest, _raw), do: {:error, {:invalid_manifest, "missing checksums"}}

  defp validate_documents(documents) when is_list(documents) do
    Enum.reduce_while(documents, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_document(entry) do
        {:ok, doc} -> {:cont, {:ok, [doc | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      {:error, _} = err -> err
    end
  end

  defp validate_documents(_), do: {:error, {:invalid_document, "documents must be a list"}}

  defp validate_document(%{"uri" => uri, "content" => content} = entry) do
    abstract = Map.get(entry, "abstract")
    overview = Map.get(entry, "overview")

    with {:ok, _} <- validate_uri(uri),
         :ok <- validate_text(content, "content"),
         :ok <- validate_optional_text(abstract, "abstract"),
         :ok <- validate_optional_text(overview, "overview") do
      {:ok, %{uri: uri, content: content, abstract: abstract, overview: overview}}
    else
      {:error, detail} -> {:error, {:invalid_document, detail}}
    end
  end

  defp validate_document(entry), do: {:error, {:invalid_document, inspect(entry)}}

  defp validate_memories(memories) when is_list(memories) do
    Enum.reduce_while(memories, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_memory(entry) do
        {:ok, memory} -> {:cont, {:ok, [memory | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, memories} -> {:ok, Enum.reverse(memories)}
      {:error, _} = err -> err
    end
  end

  defp validate_memories(_), do: {:error, {:invalid_memory, "memories must be a list"}}

  defp validate_memory(%{"uri" => uri, "assertions" => assertions}) when is_list(assertions) do
    with {:ok, _} <- validate_uri(uri),
         {:ok, ordered} <- validate_assertions(assertions) do
      {:ok, %{uri: uri, assertions: ordered}}
    else
      {:error, detail} -> {:error, {:invalid_memory, detail}}
    end
  end

  defp validate_memory(entry), do: {:error, {:invalid_memory, inspect(entry)}}

  defp validate_assertions(assertions) when is_list(assertions) and assertions != [] do
    Enum.reduce_while(assertions, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_assertion(entry) do
        {:ok, assertion} -> {:cont, {:ok, [assertion | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ordered} -> {:ok, Enum.reverse(ordered)}
      {:error, _} = err -> err
    end
  end

  defp validate_assertions(_), do: {:error, "assertions must be a non-empty list"}

  defp validate_assertion(%{"value" => value} = entry) do
    confidence = Map.get(entry, "confidence", 0.5)
    source = Map.get(entry, "source")

    with :ok <- validate_text(value, "value"),
         :ok <- validate_confidence(confidence),
         :ok <- validate_optional_text(source, "source", allow_nil: true) do
      {:ok, %{value: value, confidence: confidence * 1.0, source: source}}
    else
      {:error, detail} -> {:error, detail}
    end
  end

  defp validate_assertion(entry), do: {:error, inspect(entry)}

  defp validate_sessions(sessions) when is_list(sessions) do
    Enum.reduce_while(sessions, {:ok, []}, fn entry, {:ok, acc} ->
      case validate_session(entry) do
        {:ok, session} -> {:cont, {:ok, [session | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, sessions} -> {:ok, Enum.reverse(sessions)}
      {:error, _} = err -> err
    end
  end

  defp validate_sessions(_), do: {:error, {:invalid_session, "sessions must be a list"}}

  defp validate_session(%{"id" => id, "messages" => messages}) when is_binary(id) and is_list(messages) do
    with :ok <- validate_session_id(id),
         {:ok, ordered} <- validate_session_messages(messages) do
      {:ok, %{id: id, messages: ordered}}
    else
      {:error, detail} -> {:error, {:invalid_session, detail}}
    end
  end

  defp validate_session(entry), do: {:error, {:invalid_session, inspect(entry)}}

  defp validate_session_messages(messages) do
    Enum.reduce_while(Enum.with_index(messages), {:ok, []}, fn {entry, index}, {:ok, acc} ->
      case validate_session_message(entry, index) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ordered} -> {:ok, Enum.reverse(ordered)}
      {:error, _} = err -> err
    end
  end

  defp validate_session_message(%{"role" => role, "content" => content}, index)
       when role in ["user", "assistant", "system"] and is_binary(content) do
    if String.valid?(content) do
      {:ok, %{seq: index, role: String.to_atom(role), content: content}}
    else
      {:error, "message #{index} content is not valid UTF-8"}
    end
  end

  defp validate_session_message(entry, index), do: {:error, "message #{index} invalid: #{inspect(entry)}"}

  defp validate_uri(uri) when is_binary(uri) do
    case VikingURI.parse(uri) do
      {:ok, []} -> {:error, "URI #{inspect(uri)} must not be the root"}
      {:ok, _} -> {:ok, uri}
      {:error, :invalid_uri} -> {:error, "URI #{inspect(uri)} is invalid"}
    end
  end

  defp validate_uri(uri), do: {:error, "URI #{inspect(uri)} must be a string"}

  defp validate_text(text, field) when is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, "#{field} is not valid UTF-8"}
  end

  defp validate_text(other, field), do: {:error, "#{field} must be a string, got #{inspect(other)}"}

  defp validate_optional_text(text, field, opts \\ [])
  defp validate_optional_text(nil, _field, _opts), do: :ok

  defp validate_optional_text(text, field, _opts) when is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, "#{field} is not valid UTF-8"}
  end

  defp validate_optional_text(other, field, _opts),
    do: {:error, "#{field} must be a string or null, got #{inspect(other)}"}

  defp validate_confidence(confidence) when is_number(confidence) do
    if confidence >= 0.0 and confidence <= 1.0, do: :ok, else: {:error, "confidence #{inspect(confidence)} out of range"}
  end

  defp validate_confidence(other), do: {:error, "confidence must be a number, got #{inspect(other)}"}

  defp validate_session_id(id) do
    if byte_size(id) > 0 and String.valid?(id) and not String.contains?(id, "/") do
      :ok
    else
      {:error, "session id #{inspect(id)} invalid"}
    end
  end

  defp check_transfer_counts(documents, memories, sessions) do
    assertions = memories |> Enum.map(&(length(&1.assertions))) |> Enum.sum()
    messages = sessions |> Enum.map(&(length(&1.messages))) |> Enum.sum()
    total = length(documents) + assertions + messages

    cond do
      total > @max_entries -> {:error, {:too_many_entries, @max_entries}}
      true -> check_transfer_bytes(documents, memories, sessions)
    end
  end

  defp check_transfer_bytes(documents, memories, sessions) do
    doc_bytes = documents |> Enum.map(&(byte_size(&1.content))) |> Enum.sum()

    mem_bytes =
      memories
      |> Enum.flat_map(& &1.assertions)
      |> Enum.map(&(byte_size(&1.value)))
      |> Enum.sum()

    msg_bytes =
      sessions
      |> Enum.flat_map(& &1.messages)
      |> Enum.map(&(byte_size(&1.content)))
      |> Enum.sum()

    if doc_bytes + mem_bytes + msg_bytes > @max_bytes do
      {:error, {:too_large, @max_bytes}}
    else
      :ok
    end
  end

  # -- import: writing to the store --

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
        opts = [abstract: doc.abstract, overview: doc.overview] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

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
      {nil, _} -> true
      {_, {:ok, []}} -> false
      {tip, {:ok, [active]}} -> active.value == tip.value and active.confidence == tip.confidence and active.source == tip.source
      _ -> false
    end
  end

  defp put_source(opts, nil), do: opts
  defp put_source(opts, source), do: Keyword.put(opts, :source, source)

  defp write_sessions(sessions) do
    Enum.reduce(sessions, {:ok, 0, 0, [], []}, fn session, {:ok, sess_count, msg_count, skipped, failures} ->
      case Sessions.restore(session.id, session.messages) do
        {:ok, :imported} -> {:ok, sess_count + 1, msg_count + length(session.messages), skipped, failures}
        {:ok, :skipped} -> {:ok, sess_count + 1, msg_count + length(session.messages), [session.id | skipped], failures}
        {:error, {:session_conflict, _} = reason} -> {:ok, sess_count, msg_count, [session.id | skipped], [{session.id, reason} | failures]}
        {:error, reason} -> {:ok, sess_count, msg_count, skipped, [{session.id, reason} | failures]}
      end
    end)
    |> case do
      {:ok, sess_count, msg_count, skipped, []} -> {:ok, sess_count, msg_count, Enum.reverse(skipped), []}
      {:ok, sess_count, msg_count, skipped, failures} ->
        # Conflicts are skips, not failures: report them as skipped and succeed
        # unless a real storage error occurred.
        {conflicts, hard} = Enum.split_with(failures, fn {_id, reason} -> match?({:session_conflict, _}, reason) end)

        if hard == [] do
          {:ok, sess_count, msg_count, Enum.reverse(skipped), []}
        else
          {:ok, sess_count, msg_count, Enum.reverse(skipped) ++ Enum.map(conflicts, &elem(&1, 0)), hard}
        end
    end
  end
end
