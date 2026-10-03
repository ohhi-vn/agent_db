defmodule AgentDb.Application.DataTransfer.Manifest do
  @moduledoc """
  The on-the-wire shape of a transfer archive: its members, its manifest, and
  the validation every entry must pass.

  A transfer archive is four JSON members -- `manifest.json` plus the documents,
  memories, and sessions it carries -- and this module is everything about those
  bytes that is not the container itself. Encoding a payload into members and
  turning read members back into a validated payload are the same question asked
  in two directions, and both belong here rather than in the workflow that walks
  the store.

  Two rules run through all of it:

    * **Nothing is written until everything is accepted.** Every function returns
      either a value or a reason for refusing the whole archive, so a caller that
      writes only on success leaves the store untouched.
    * **The bounds are passed in, not declared here.** The transfer module's
      `limits/0` is where they are defined and documented; this module is handed
      them, so the format cannot drift from the transfer that uses it.

  `AgentDb.Archive` owns the container this content is packed into, in both
  directions. The transfer module owns the walk over the store and the writes
  that restore it.
  """

  alias AgentDb.Archive
  alias AgentDb.URI, as: VikingURI

  @typedoc "The bounds one transfer accepts: entries, and expanded bytes."
  @type limits :: %{max_entries: pos_integer(), max_bytes: pos_integer()}

  @format_version 1

  @manifest_name "manifest.json"
  @documents_name "documents.json"
  @memories_name "memories.json"
  @sessions_name "sessions.json"
  @expected_members [@manifest_name, @documents_name, @memories_name, @sessions_name]

  @doc "The format version this module writes, and the only one it reads."
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  The archive's members, in the order they are written.

  Both directions of a transfer need this list, so only one place decides what a
  transfer archive contains.
  """
  @spec members(binary(), binary(), binary(), binary()) :: [{String.t(), binary()}]
  def members(manifest_json, documents_json, memories_json, sessions_json) do
    [
      {@manifest_name, manifest_json},
      {@documents_name, documents_json},
      {@memories_name, memories_json},
      {@sessions_name, sessions_json}
    ]
  end

  @doc "Encodes the three collections as the JSON members an archive carries."
  @spec encode_payload([map()], [map()], [map()]) ::
          {:ok, {binary(), binary(), binary()}} | {:error, term()}
  def encode_payload(documents, memories, sessions) do
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

  @doc """
  The manifest: format version, the scope the export covered, when it ran, what
  it carried, and a checksum per member.
  """
  @spec encode(String.t() | nil, [map()], [map()], [map()], binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encode(scope, documents, memories, sessions, docs_json, mems_json, sess_json) do
    message_count = sessions |> Enum.map(&length(&1.messages)) |> Enum.sum()

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
        documents: Archive.digest(docs_json),
        memories: Archive.digest(mems_json),
        sessions: Archive.digest(sess_json)
      }
    }

    case Jason.encode(manifest) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid_manifest, inspect(reason)}}
    end
  end

  @doc "Refuses a payload holding more entries than the transfer accepts."
  @spec check_counts([map()], [map()], [map()], limits()) :: :ok | {:error, term()}
  def check_counts(documents, memories, sessions, limits) do
    assertions = memories |> Enum.map(&length(&1.assertions)) |> Enum.sum()
    messages = sessions |> Enum.map(&length(&1.messages)) |> Enum.sum()
    total = length(documents) + assertions + messages

    if total > limits.max_entries,
      do: {:error, {:too_many_entries, limits.max_entries}},
      else: :ok
  end

  @doc "Refuses encoded members larger than the transfer's byte bound."
  @spec check_bytes(binary(), binary(), binary(), limits()) :: :ok | {:error, term()}
  def check_bytes(docs_json, mems_json, sess_json, limits) do
    total = byte_size(docs_json) + byte_size(mems_json) + byte_size(sess_json)

    if total > limits.max_bytes, do: {:error, {:too_large, limits.max_bytes}}, else: :ok
  end

  @doc """
  Refuses an archive holding more members than the bound allows, a name twice, a
  name that is not one of the four, or a name that escapes the archive root.
  """
  @spec check_members([{String.t(), binary()}], limits()) :: :ok | {:error, term()}
  def check_members(members, limits) do
    names = Enum.map(members, fn {name, _content} -> name end)

    with :ok <- check_count(length(members), limits),
         :ok <- check_duplicates(names),
         :ok <- check_expected(names),
         :ok <- check_names_safe(names) do
      :ok
    end
  end

  defp check_count(count, limits) when count > limits.max_entries,
    do: {:error, {:too_many_entries, limits.max_entries}}

  defp check_count(_, _limits), do: :ok

  @doc """
  Refuses a binary larger than the transfer's byte bound.

  Checked against the archive as it arrived, before it is expanded, and again
  against what its members hold once they are decoded.
  """
  @spec check_size(non_neg_integer(), limits()) :: :ok | {:error, term()}
  def check_size(bytes, limits) when bytes > limits.max_bytes,
    do: {:error, {:too_large, limits.max_bytes}}

  def check_size(_, _limits), do: :ok

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
      if safe_member_name?(name),
        do: {:cont, :ok},
        else: {:halt, {:error, {:unexpected_entry, name}}}
    end)
  end

  defp safe_member_name?(name) do
    not String.starts_with?(name, "/") and ".." not in String.split(name, "/") and
      not String.contains?(name, "\\") and String.valid?(name)
  end

  @doc """
  Decodes the members into terms.

  The raw JSON of each member is kept alongside, because the manifest's checksums
  are over the bytes as they arrived rather than over the decoded terms.
  """
  @spec decode([{String.t(), binary()}]) :: {:ok, map()} | {:error, term()}
  def decode(members) do
    by_name = Map.new(members)

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

  @doc """
  Validates a decoded archive whole: the manifest against what it claims, then
  every document, memory, and session, then the bounds again on what they hold.

  Nothing is written by any of it, so a caller that writes only on success leaves
  the store exactly as it was.
  """
  @spec validate_payload(map(), limits()) :: {:ok, map()} | {:error, term()}
  def validate_payload(
        %{
          manifest: manifest,
          documents: documents,
          memories: memories,
          sessions: sessions,
          raw: raw
        },
        limits
      ) do
    with :ok <- validate_manifest(manifest, documents, memories, sessions, raw),
         {:ok, documents} <- validate_documents(documents),
         {:ok, memories} <- validate_memories(memories),
         {:ok, sessions} <- validate_sessions(sessions),
         :ok <- check_transfer_counts(documents, memories, sessions, limits) do
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

  defp validate_manifest(_other, _d, _m, _s, _r),
    do: {:error, {:invalid_manifest, "manifest must be an object"}}

  defp fetch_version(%{"format_version" => version}) when is_integer(version), do: {:ok, version}
  defp fetch_version(_), do: {:error, {:invalid_manifest, "missing format_version"}}

  defp check_version(@format_version), do: :ok

  defp check_version(version) when is_integer(version) and version > @format_version,
    do: {:error, {:unsupported_version, version}}

  defp check_version(version),
    do: {:error, {:invalid_manifest, "bad format_version #{inspect(version)}"}}

  defp check_counts_match(%{"counts" => counts}, documents, memories, sessions)
       when is_map(counts) and is_list(documents) and is_list(memories) and is_list(sessions) do
    message_count = sessions |> Enum.map(&length(Map.get(&1, "messages", []))) |> Enum.sum()

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

  defp check_counts_match(_manifest, _d, _m, _s),
    do: {:error, {:invalid_manifest, "missing counts"}}

  defp check_checksums(%{"checksums" => checksums}, raw) when is_map(checksums) do
    Enum.reduce_while(@expected_members -- [@manifest_name], :ok, fn name, :ok ->
      expected = Map.get(checksums, String.trim_trailing(name, ".json"))

      if expected == Archive.digest(raw[name]) do
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

  defp validate_session(%{"id" => id, "messages" => messages})
       when is_binary(id) and is_list(messages) do
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

  defp validate_session_message(entry, index),
    do: {:error, "message #{index} invalid: #{inspect(entry)}"}

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

  defp validate_text(other, field),
    do: {:error, "#{field} must be a string, got #{inspect(other)}"}

  defp validate_optional_text(text, field, opts \\ [])
  defp validate_optional_text(nil, _field, _opts), do: :ok

  defp validate_optional_text(text, field, _opts) when is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, "#{field} is not valid UTF-8"}
  end

  defp validate_optional_text(other, field, _opts),
    do: {:error, "#{field} must be a string or null, got #{inspect(other)}"}

  defp validate_confidence(confidence) when is_number(confidence) do
    if confidence >= 0.0 and confidence <= 1.0,
      do: :ok,
      else: {:error, "confidence #{inspect(confidence)} out of range"}
  end

  defp validate_confidence(other),
    do: {:error, "confidence must be a number, got #{inspect(other)}"}

  defp validate_session_id(id) do
    if byte_size(id) > 0 and String.valid?(id) and not String.contains?(id, "/") do
      :ok
    else
      {:error, "session id #{inspect(id)} invalid"}
    end
  end

  defp check_transfer_counts(documents, memories, sessions, limits) do
    assertions = memories |> Enum.map(&length(&1.assertions)) |> Enum.sum()
    messages = sessions |> Enum.map(&length(&1.messages)) |> Enum.sum()
    total = length(documents) + assertions + messages

    if total > limits.max_entries do
      {:error, {:too_many_entries, limits.max_entries}}
    else
      check_transfer_bytes(documents, memories, sessions, limits)
    end
  end

  defp check_transfer_bytes(documents, memories, sessions, limits) do
    doc_bytes = documents |> Enum.map(&byte_size(&1.content)) |> Enum.sum()

    mem_bytes =
      memories
      |> Enum.flat_map(& &1.assertions)
      |> Enum.map(&byte_size(&1.value))
      |> Enum.sum()

    msg_bytes =
      sessions
      |> Enum.flat_map(& &1.messages)
      |> Enum.map(&byte_size(&1.content))
      |> Enum.sum()

    if doc_bytes + mem_bytes + msg_bytes > limits.max_bytes do
      {:error, {:too_large, limits.max_bytes}}
    else
      :ok
    end
  end
end
