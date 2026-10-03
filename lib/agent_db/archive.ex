defmodule AgentDb.Archive do
  @moduledoc """
  A bounded tar archive, optionally gzipped, in both directions.

  Two unrelated features accept a tar file a user chose: an Agent Skill bundle
  and a data-transfer archive. Both had the same gzip inflater, the same listing
  and extraction calls, and the same two bounds written out twice — which is how
  two safety-critical copies drift apart while each one's own tests still pass.
  This is that code once, and writing is here for the same reason: the exporter and
  the format it writes must not each hold their own idea of what an archive is.

  The bound is a parameter rather than a module attribute because the two callers
  accept different sizes, and the bound is the whole point of the module.

  ## The two bounds

  An archive is listed before it is read, so the whole of it can be refused
  before a byte is expanded:

    * the **declared** total, taken from the headers, refuses a bundle that
      announces itself as too large; and
    * the **actual** total, checked while inflating and again while extracting,
      which is what holds when a header lies about what its member holds.

  Gzip is undone here rather than by the tar reader, and through the streaming
  inflater, because a compressed archive is inflated whole before a tar reader
  could bound it. The tar reader is handed plain bytes, and the inflated total
  is bounded before it is ever assembled.
  """

  @typedoc "One member of an archive, as its header describes it."
  @type member :: %{name: String.t(), type: :regular | :directory, size: non_neg_integer()}

  @doc """
  Every member of `binary`.

  Refuses a bundle holding more than `max_entries` members or declaring more than
  `max_bytes`, and refuses the whole archive for any member that is not a regular
  file or a directory — a symbolic link, a hard link, or a device entry is caught
  from the listing, before its contents are read.
  """
  @spec list(binary(), pos_integer(), pos_integer()) :: {:ok, [member()]} | {:error, term()}
  def list(binary, max_entries, max_bytes) do
    with {:ok, tar} <- plain_tar(binary, max_bytes),
         {:ok, rows} <- table(tar),
         :ok <- check_entries(length(rows), max_entries),
         {:ok, members} <- members(rows),
         :ok <- check_size(declared_size(members), max_bytes) do
      {:ok, members}
    end
  end

  @doc """
  The contents of every regular member, as `%{name => binary}`.

  Bounded again by what is actually read rather than by what was declared: a
  header can claim a size its member does not have. A directory contributes no
  content.
  """
  @spec extract(binary(), pos_integer()) ::
          {:ok, %{optional(String.t()) => binary()}} | {:error, term()}
  def extract(binary, max_bytes) do
    with {:ok, tar} <- plain_tar(binary, max_bytes) do
      case :erl_tar.extract({:binary, tar}, [:memory, {:max_size, max_bytes}]) do
        {:ok, members} ->
          {:ok, Map.new(members, fn {name, content} -> {List.to_string(name), content} end)}

        {:error, :too_big} ->
          too_large(max_bytes)

        {:error, reason} ->
          {:error, {:malformed_archive, reason}}
      end
    end
  end

  @doc "The total size the headers declare across the regular members."
  @spec declared_size([member()]) :: non_neg_integer()
  def declared_size(members) do
    Enum.reduce(members, 0, fn
      %{type: :regular, size: size}, total -> total + size
      _other, total -> total
    end)
  end

  @doc """
  The bytes an archive holds once expanded, bounded by `max_bytes`.

  Gzip is detected by its magic bytes rather than by a file name, so a `.tar.gz`
  that is not gzip and a tar that happens to be called one are each reported for
  what they are.
  """
  @spec plain_tar(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def plain_tar(<<0x1F, 0x8B, _rest::binary>> = binary, max_bytes), do: inflate(binary, max_bytes)
  def plain_tar(binary, _max_bytes), do: {:ok, binary}

  @doc """
  Packs `members` into an uncompressed tar binary.

  `:erl_tar` writes to a path rather than to memory, so the archive is built in a
  scratch file and read back; the file is removed whether or not the build
  succeeded. The result is the same bytes `write/3` would put on disk, which is
  what makes an in-memory transfer and a file transfer the same format.

  `members` is a list of `{name, content}` with `name` a string.
  """
  @spec build([{String.t(), binary()}]) :: {:ok, binary()} | {:error, term()}
  def build(members) do
    path =
      Path.join(System.tmp_dir!(), "agent_db_archive_#{System.unique_integer([:positive])}.tar")

    try do
      case :erl_tar.create(String.to_charlist(path), charlist_members(members), []) do
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

  @doc """
  Writes `members` to `path` as a tar, gzip compressed when asked.

  `compressed` is passed rather than inferred from the file name: whether an
  archive is compressed is a property of the caller's destination, and the
  reading side detects gzip by its content rather than by its extension, so a
  name never decides what the bytes are.
  """
  @spec write(Path.t(), [{String.t(), binary()}], boolean()) :: :ok | {:error, term()}
  def write(path, members, compressed) do
    :ok = File.mkdir_p(Path.dirname(path))
    opts = if compressed, do: [:compressed], else: []

    case :erl_tar.create(String.to_charlist(path), charlist_members(members), opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unreadable_source, reason, path}}
    end
  end

  @doc """
  The lower-case hex SHA-256 of `binary`.

  The digest a transfer manifest records and re-checks. It lives here because
  the checksum is over the bytes that were packed, which is the same question the
  container answers.
  """
  @spec digest(binary()) :: String.t()
  def digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp charlist_members(members) do
    Enum.map(members, fn {name, content} -> {String.to_charlist(name), content} end)
  end

  # A single unsupported entry refuses the whole archive rather than being
  # skipped: a bundle holding a link is not a bundle this store can store as it
  # is, and dropping the link would import the bundle as something other than
  # what the user chose.
  defp members(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case member(row) do
        {:ok, member} -> {:cont, {:ok, [member | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp member({charlist, :regular, size, _mtime, _mode, _uid, _gid}),
    do: {:ok, %{name: List.to_string(charlist), type: :regular, size: size}}

  defp member({charlist, :directory, size, _mtime, _mode, _uid, _gid}),
    do: {:ok, %{name: List.to_string(charlist), type: :directory, size: size}}

  defp member({charlist, type, _size, _mtime, _mode, _uid, _gid}),
    do: {:error, {:unsupported_entry, type, List.to_string(charlist)}}

  defp inflate(binary, max_bytes) do
    zlib = :zlib.open()

    try do
      :zlib.inflateInit(zlib, 31)
      inflate_loop(zlib, binary, 0, [], max_bytes)
    catch
      # Bytes that are not a complete gzip stream come back as an exception
      # rather than as an answer, and are no more readable than a broken tar.
      _kind, reason -> {:error, {:malformed_archive, reason}}
    after
      :zlib.close(zlib)
    end
  end

  defp inflate_loop(zlib, input, total, acc, max_bytes) do
    case :zlib.safeInflate(zlib, input) do
      {:finished, output} ->
        assemble(total + :erlang.iolist_size(output), [acc | output], max_bytes)

      {:continue, output} ->
        expand(zlib, total + :erlang.iolist_size(output), [acc | output], max_bytes)

      {:need_dictionary, _adler, _output} ->
        {:error, {:malformed_archive, :needs_dictionary}}
    end
  end

  defp expand(_zlib, total, _acc, max_bytes) when total > max_bytes, do: too_large(max_bytes)

  defp expand(zlib, total, acc, max_bytes),
    do: inflate_loop(zlib, [], total, acc, max_bytes)

  # The bound is checked here as well as on the way: an archive that expands in
  # one go must not be assembled before it is refused.
  defp assemble(total, _acc, max_bytes) when total > max_bytes, do: too_large(max_bytes)
  defp assemble(_total, acc, _max_bytes), do: {:ok, :erlang.iolist_to_binary(acc)}

  defp table(tar) do
    case :erl_tar.table({:binary, tar}, [:verbose]) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:malformed_archive, reason}}
    end
  end

  defp check_entries(count, max_entries) when count > max_entries,
    do: {:error, {:too_many_entries, max_entries}}

  defp check_entries(_count, _max_entries), do: :ok

  defp check_size(total, max_bytes) when total > max_bytes, do: too_large(max_bytes)
  defp check_size(_total, _max_bytes), do: :ok

  defp too_large(max_bytes), do: {:error, {:too_large, max_bytes}}
end
