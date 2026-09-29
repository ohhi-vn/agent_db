defmodule AgentDb.Skills.Source do
  @moduledoc """
  Reading an Agent Skills bundle, and refusing one that cannot be stored as it is.

  Every entry point -- the console's upload, a folder on disk, a tar archive --
  arrives here, so what counts as a skill is decided in exactly one place. What
  comes out is a list of skills, each a name and its files at the paths they had
  inside the bundle, and nothing has been written anywhere.

  ## What a source may look like

    * one skill directory, with a `SKILL.md` at its root, and
    * a collection of immediate skill directories, each with a `SKILL.md`.

  A folder that holds a `SKILL.md` at its own root is that one skill, and takes
  its name from the folder. An archive may add one common wrapper directory
  above the skills, which is how a repository is usually archived; it is
  recognised only when every member sits beneath it and the skills are inside
  it. The directory name of a skill is its name; nothing inside `SKILL.md` is
  parsed, so a skill is preserved exactly as its author wrote it.

  ## What is refused

  An unsafe path (absolute, traversing, backslashed, carrying control
  characters, or holding an empty segment), a non-regular file, a symbolic or
  hard link, a duplicate path, a path stored both as a file and a directory, a
  skill with no `SKILL.md`, and a file that is not valid UTF-8. Files are read
  as text because that is what the store holds; a binary asset is reported
  rather than mangled.

  Archive members are read in memory and never extracted to disk, and the two
  limits in `limits/0` bound the entries and the expanded bytes of one source,
  so a small archive cannot cost an unbounded amount of work.

  ## Why the limits are here and not in configuration

  The console and the Mix task have to accept the same bundles, and a limit
  that could be set differently on each would make that untrue. They are
  therefore one set of numbers, published by `limits/0` so that a caller
  configures its own caps to match rather than restating them.
  """

  alias AgentDb.URI, as: VikingURI

  @manifest "SKILL.md"

  @max_entries 500
  @max_bytes 5_000_000

  @typedoc "One file as a browser sent it: a client-relative path and its bytes."
  @type upload :: %{path: String.t(), content: binary()}

  @typedoc """
  Where a bundle comes from.

  `:path` is a directory or an archive on disk, `:archive` the bytes of one, and
  `:uploads` the files of a browser directory selection.
  """
  @type source :: {:path, Path.t()} | {:archive, binary()} | {:uploads, [upload()]}

  @typedoc "One file of a skill, at `path` below the skill's root."
  @type file :: %{path: [String.t()], content: String.t()}

  @typedoc "A skill ready to be stored: its name, and every file it holds."
  @type skill :: %{name: String.t(), files: [file()]}

  @doc "The bounds one import accepts: entries, and expanded bytes."
  @spec limits() :: %{max_entries: pos_integer(), max_bytes: pos_integer()}
  def limits, do: %{max_entries: @max_entries, max_bytes: @max_bytes}

  @doc """
  Reads a source into the skills it holds.

  A refusal is about the whole source, never about one file of it. Nothing is
  written while a source is being read, so a rejected bundle cannot leave half
  of itself stored, and `message/1` turns whatever comes back into a sentence
  for the operator.
  """
  @spec load(source()) :: {:ok, [skill()]} | {:error, term()}
  def load({:path, path}) do
    with {:ok, read, name} <- read_path(path), do: finish(read, name)
  end

  def load({:archive, binary}) do
    with :ok <- check_size(byte_size(binary)),
         {:ok, read} <- read_archive(binary) do
      finish(read)
    end
  end

  def load({:uploads, uploads}) when is_list(uploads) do
    uploads
    |> Enum.reduce_while({:ok, new_read()}, fn upload, {:ok, read} ->
      case add_upload(read, upload) do
        {:ok, read} -> {:cont, {:ok, read}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} -> finish(read)
      {:error, _} = error -> error
    end
  end

  @doc """
  Why an import was refused, as a sentence an operator can act on.

  Every refusal an import can report is answered here, the destination's as well
  as the source's, so a caller has one way to turn a reason into something worth
  showing rather than a format of its own per surface.
  """
  @spec message(term()) :: String.t()
  def message({:invalid_user_id, name}),
    do: "#{inspect(name)} cannot be a user id: it is not one URI segment"

  def message({:no_skills}), do: "the source holds no files"

  def message({:missing_manifest, name}),
    do: "#{name} has no #{@manifest} at its root"

  def message({:loose_file, path}),
    do: "#{path} is a file where a skill directory was expected"

  def message({:duplicate_path, path}), do: "#{path} appears more than once"

  def message({:path_conflict, path}),
    do: "#{path} is stored both as a file and as a directory"

  def message({:unsafe_path, path, detail}),
    do: "#{path} cannot be stored: #{path_detail(detail)}"

  def message({:invalid_utf8, path}), do: "#{path} is not valid UTF-8 text"

  def message({:too_many_entries, limit}),
    do: "the source holds more than #{limit} entries"

  def message({:too_large, limit}),
    do: "the source is larger than #{limit} bytes once expanded"

  def message({:unsupported_entry, type, path}),
    do: "#{path} is a #{type}, not a regular file or a directory"

  def message({:unsupported_source, type, path}),
    do: "#{path} is a #{type}, not a directory or an archive"

  def message({:unreadable_source, reason, path}),
    do: "#{path} could not be read: #{inspect(reason)}"

  def message({:malformed_archive, reason}),
    do: "the archive could not be read: #{inspect(reason)}"

  def message(reason), do: inspect(reason)

  # -- a folder on disk --

  # A folder may be the skill it holds, in which case the name of the folder is
  # the name of the skill. An archive has no name of its own to lend, so one is
  # never taken from it.
  defp read_path(path) do
    case lstat(path) do
      {:ok, %{type: :directory}} -> named(walk(path, [], new_read()), Path.basename(path))
      {:ok, %{type: :regular, size: size}} -> unnamed(read_archive_file(path, size))
      {:ok, %{type: type}} -> {:error, {:unsupported_source, type, path}}
      {:error, reason} -> {:error, {:unreadable_source, reason, path}}
    end
  end

  defp named({:ok, read}, name), do: {:ok, read, name}
  defp named({:error, _} = error, _name), do: error

  defp unnamed({:ok, read}), do: {:ok, read, nil}
  defp unnamed({:error, _} = error), do: error

  # lstat, not stat: a source that is a link to somewhere else is refused rather
  # than followed, so a link cannot reach outside what was named.
  defp lstat(path), do: File.lstat(path)

  defp read_archive_file(path, size) do
    with :ok <- check_size(size),
         {:ok, binary} <- read_file(path) do
      read_archive(binary)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:unreadable_source, reason, path}}
    end
  end

  defp walk(dir, prefix, read) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, read}, fn name, {:ok, read} ->
          case descend(dir, name, prefix, read) do
            {:ok, read} -> {:cont, {:ok, read}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, reason} ->
        {:error, {:unreadable_source, reason, display(prefix)}}
    end
  end

  defp descend(dir, name, prefix, read) do
    child = Path.join(dir, name)

    with {:ok, path} <- normalize(prefix, name) do
      case lstat(child) do
        {:ok, %{type: :directory}} ->
          with {:ok, read} <- add_dir(read, path) do
            walk(child, path, read)
          end

        {:ok, %{type: :regular, size: size}} ->
          with :ok <- check_size(size),
               {:ok, binary} <- read_file(child) do
            add_file(read, path, binary)
          end

        {:ok, %{type: type}} ->
          {:error, {:unsupported_entry, type, display(path)}}

        {:error, reason} ->
          {:error, {:unreadable_source, reason, child}}
      end
    end
  end

  # -- an archive --

  # The archive is listed before it is read. A listing carries every member's
  # type and declared size, so the whole bundle can be refused before a byte of
  # it is expanded, and a member that is a link or a device is caught before it
  # is ever handed over.
  defp read_archive(binary) do
    with {:ok, tar} <- plain_tar(binary),
         {:ok, rows} <- table(tar),
         :ok <- check_count(length(rows)),
         :ok <- check_size(declared_size(rows)),
         {:ok, read} <- read_rows(rows, new_read()) do
      attach(tar, read)
    end
  end

  # Gzip is undone here, through the streaming inflater, rather than by the tar
  # reader: a compressed archive is inflated whole before any caller could bound
  # it, and the streaming one exists for input that cannot be trusted to stay
  # the size it looks. What the tar reader is handed is therefore plain bytes,
  # and the inflated total is bounded before it is ever assembled.
  defp plain_tar(<<0x1F, 0x8B, _rest::binary>> = binary), do: inflate(binary)
  defp plain_tar(binary), do: {:ok, binary}

  defp inflate(binary) do
    zlib = :zlib.open()

    try do
      :zlib.inflateInit(zlib, 31)
      inflate_loop(zlib, binary, 0, [])
    catch
      # Bytes that are not a complete gzip stream come back as an exception
      # rather than as an answer, and are no more readable than a broken tar.
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

  # The bound is checked here as well as on the way: an archive that expands in
  # one go must not be assembled before it is refused.
  defp assemble(total, _acc) when total > @max_bytes, do: {:error, {:too_large, @max_bytes}}
  defp assemble(_total, acc), do: {:ok, :erlang.iolist_to_binary(acc)}

  defp table(tar) do
    case :erl_tar.table({:binary, tar}, [:verbose]) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:malformed_archive, reason}}
    end
  end

  # Declared rather than actual, because a header can lie: the bound on what is
  # actually read is the extraction's own, below. This one is what refuses a
  # bundle before any of it has been expanded.
  defp declared_size(rows) do
    sizes = for {_name, type, size, _mtime, _mode, _uid, _gid} <- rows, type == :regular, do: size
    Enum.sum(sizes)
  end

  defp read_rows(rows, read) do
    Enum.reduce_while(rows, {:ok, read}, fn row, {:ok, read} ->
      case read_row(read, row) do
        {:ok, read} -> {:cont, {:ok, read}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp read_row(read, {charlist, :directory, _size, _mtime, _mode, _uid, _gid}) do
    with {:ok, name} <- normalize_name(charlist),
         {:ok, path} <- normalize([], name) do
      add_dir(read, path)
    end
  end

  defp read_row(read, {charlist, :regular, _size, _mtime, _mode, _uid, _gid}) do
    with {:ok, name} <- normalize_name(charlist),
         {:ok, path} <- normalize([], name) do
      add_pending(read, path, charlist)
    end
  end

  defp read_row(_read, {charlist, type, _size, _mtime, _mode, _uid, _gid}) do
    case normalize_name(charlist) do
      {:ok, name} -> {:error, {:unsupported_entry, type, name}}
      {:error, _} = error -> error
    end
  end

  # The listing and the extraction read the same archive in the same order, so a
  # member of one is a member of the other. Contents are attached to the entries
  # the listing already accepted rather than examined a second time.
  defp attach(tar, read) do
    case extract(tar) do
      {:ok, members} -> fill(read, members)
      {:error, _} = error -> error
    end
  end

  defp extract(tar) do
    # A second bound, on what is read rather than on what was declared: a header
    # can claim a size the member does not have.
    case :erl_tar.extract({:binary, tar}, [:memory, {:max_size, @max_bytes}]) do
      {:ok, members} -> {:ok, Map.new(members)}
      {:error, :too_big} -> {:error, {:too_large, @max_bytes}}
      {:error, reason} -> {:error, {:malformed_archive, reason}}
    end
  end

  defp fill(read, members) do
    read.entries
    |> Enum.reduce_while({:ok, []}, fn
      {:dir, _path, _name} = entry, {:ok, acc} ->
        {:cont, {:ok, [entry | acc]}}

      {:file, path, name, :pending}, {:ok, acc} ->
        case Map.fetch(members, name) do
          {:ok, content} -> {:cont, {:ok, [{:file, path, name, content} | acc]}}
          :error -> {:halt, {:error, {:malformed_archive, {:missing, List.to_string(name)}}}}
        end
    end)
    |> case do
      {:ok, entries} -> {:ok, %{read | entries: Enum.reverse(entries)}}
      {:error, _} = error -> error
    end
  end

  # -- a browser's files --

  defp add_upload(read, %{path: name, content: content}) when is_binary(content) do
    with {:ok, path} <- normalize([], name), do: add_file(read, path, content)
  end

  # -- the bounded read --

  # A read accumulates the entries it has accepted and the two numbers the limits
  # are enforced against, and stops at the first refusal: a source that is
  # rejected never costs more than the limit it exceeded.
  defp new_read, do: %{entries: [], count: 0, bytes: 0}

  defp add_dir(read, path) do
    with :ok <- check_count(read.count + 1) do
      {:ok,
       %{read | entries: [{:dir, path, List.last(path)} | read.entries], count: read.count + 1}}
    end
  end

  defp add_file(read, path, binary) do
    with :ok <- check_count(read.count + 1),
         :ok <- check_size(read.bytes + byte_size(binary)),
         :ok <- check_utf8(path, binary) do
      {:ok,
       %{
         read
         | entries: [{:file, path, List.last(path), binary} | read.entries],
           count: read.count + 1,
           bytes: read.bytes + byte_size(binary)
       }}
    end
  end

  # An archive member's bytes are counted as they are read, by the extraction
  # rather than here, so that a size no header declared cannot slip past.
  defp add_pending(read, path, name) do
    with :ok <- check_count(read.count + 1) do
      {:ok,
       %{read | entries: [{:file, path, name, :pending} | read.entries], count: read.count + 1}}
    end
  end

  defp check_count(count) when count > @max_entries,
    do: {:error, {:too_many_entries, @max_entries}}

  defp check_count(_count), do: :ok

  defp check_size(bytes) when bytes > @max_bytes, do: {:error, {:too_large, @max_bytes}}
  defp check_size(_bytes), do: :ok

  # Stored content is text, so a file that is not UTF-8 is reported rather than
  # silently mangled into a document that reads differently from its source.
  defp check_utf8(path, binary) do
    if String.valid?(binary), do: :ok, else: {:error, {:invalid_utf8, display(path)}}
  end

  # -- paths --

  # The same rules the context store writes URIs by, so a name that would be
  # refused there is refused here, before it can become half a URI. The rule is
  # the URI module's; what is added is the reason, for the operator.
  defp normalize(prefix, name) do
    with {:ok, name} <- to_text(name), do: validate(name, String.split(name, "/"), prefix)
  end

  defp normalize_name(charlist) do
    with {:ok, name} <- to_text(List.to_string(charlist)), do: {:ok, name}
  end

  defp to_text(name) do
    if String.valid?(name),
      do: {:ok, name},
      else: {:error, {:unsafe_path, inspect(name), :invalid_utf8}}
  end

  # The prefix is the path already walked, so each segment is joined onto the
  # path it will actually be stored at rather than onto nothing.
  defp validate(name, segments, prefix) do
    Enum.reduce_while(segments, {:ok, prefix}, fn segment, {:ok, acc} ->
      case VikingURI.join(acc, segment) do
        {:ok, acc} ->
          {:cont, {:ok, acc}}

        {:error, :invalid_uri} ->
          {:halt, {:error, {:unsafe_path, relative(prefix, name), detail(name)}}}
      end
    end)
  end

  defp detail(name) do
    segments = String.split(name, "/")

    cond do
      String.starts_with?(name, "/") -> :absolute
      ".." in segments -> :traversal
      String.contains?(name, "\\") -> :backslash
      Enum.any?(segments, &has_control_char?/1) -> :control_character
      "" in segments -> :empty_segment
      true -> :invalid
    end
  end

  defp has_control_char?(text) do
    text |> String.to_charlist() |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))
  end

  defp path_detail(:absolute), do: "an absolute path is not storable"
  defp path_detail(:traversal), do: "'..' is not a segment a URI can hold"
  defp path_detail(:backslash), do: "backslashes are not URI separators"
  defp path_detail(:control_character), do: "control characters are not storable"
  defp path_detail(:empty_segment), do: "an empty segment is not a URI segment"
  defp path_detail(:invalid_utf8), do: "the name is not valid UTF-8"
  defp path_detail(_other), do: "it is not a single valid URI segment"

  # -- the layout of what was read --

  defp finish(read, root \\ nil) do
    files =
      for {:file, path, _name, content} <- read.entries, do: %{path: path, content: content}

    files = Enum.sort_by(files, & &1.path)
    dirs = for {:dir, path, _name} <- read.entries, do: path

    with :ok <- check_duplicates(files),
         :ok <- check_conflicts(files),
         {:ok, skills} <- group(files, dirs, root) do
      {:ok, skills}
    end
  end

  defp check_duplicates(files) do
    case duplicate(files) do
      nil -> :ok
      path -> {:error, {:duplicate_path, display(path)}}
    end
  end

  defp duplicate(files) do
    files
    |> Enum.map(& &1.path)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn path, {:ok, seen} ->
      if MapSet.member?(seen, path) do
        {:halt, {:duplicate, path}}
      else
        {:cont, {:ok, MapSet.put(seen, path)}}
      end
    end)
    |> case do
      {:duplicate, path} -> path
      {:ok, _seen} -> nil
    end
  end

  # A path cannot be a file and the directory holding other files at once.
  # Checked from the shorter side, since every proper prefix of a stored path is
  # itself a path in the source.
  defp check_conflicts(files) do
    paths = MapSet.new(files, & &1.path)

    conflict =
      Enum.find_value(files, fn %{path: path} ->
        Enum.find_value(ancestors(path), &if(MapSet.member?(paths, &1), do: &1))
      end)

    case conflict do
      nil -> :ok
      path -> {:error, {:path_conflict, display(path)}}
    end
  end

  defp ancestors(path), do: for(take <- (length(path) - 1)..1//-1, do: Enum.take(path, take))

  # A folder that is itself a skill: its manifest is at its root, and its name
  # is the name of the folder it was read from. An archive has no name of its
  # own, so an archive of loose files is not a skill, and is reported below as
  # the collection it fails to be.
  defp group(files, dirs, root) do
    case root_skill(files, root) do
      :collection -> group(files, dirs)
      {:ok, skill} -> {:ok, [skill]}
      {:error, _} = error -> error
    end
  end

  defp root_skill(_files, nil), do: :collection

  defp root_skill(files, name) do
    with {:ok, [name]} <- normalize([], name) do
      if manifest?(files, [@manifest]) do
        {:ok, %{name: name, files: files}}
      else
        :collection
      end
    end
  end

  defp group([], []), do: {:error, {:no_skills}}

  defp group([], [dir | _]), do: {:error, {:missing_manifest, display(dir)}}

  # One skill directory is the whole source when the only thing in it has a
  # manifest and nothing sits beside it; anything else is a collection of skill
  # directories, and a directory beside it that has no manifest is a skill of the
  # collection that is missing one.
  defp group(files, dirs) do
    case skill_root(files, dirs) do
      {:ok, name} -> {:ok, [%{name: name, files: below(files, [name])}]}
      :collection -> collection(files, dirs)
    end
  end

  defp skill_root(files, dirs) do
    case top_level(files) do
      [name] ->
        if manifest?(files, [name, @manifest]) and not beside?(dirs, name),
          do: {:ok, name},
          else: :collection

      _many ->
        :collection
    end
  end

  defp beside?(dirs, name), do: Enum.any?(dirs, fn [other | _] -> other != name end)

  defp collection(files, dirs) do
    base = wrapper(files)
    level = length(base) + 1

    with :ok <- check_loose(files, level) do
      names(files, dirs, level)
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, skills} ->
        case collect_skill(files, base, name) do
          {:ok, skill} -> {:cont, {:ok, skills ++ [skill]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # An archive of a repository has one directory above its skills. It is
  # recognised only when everything in the source sits beneath that one directory
  # and the skills are inside it, so a source is never unwrapped because it
  # happened to have a single top-level entry.
  defp wrapper(files) do
    case top_level(files) do
      [name] ->
        if manifest?(files, [name, @manifest]) or not nested_manifest?(files),
          do: [],
          else: [name]

      _many ->
        []
    end
  end

  # The skills are inside the one directory rather than beside it, which is what
  # makes it a wrapper rather than a skill of its own.
  defp nested_manifest?(files), do: Enum.any?(files, &match?([_, _, @manifest], &1.path))

  # A file where a skill directory belongs: the source is neither one skill nor a
  # collection, and naming the file says more than refusing silently.
  defp check_loose(files, level) do
    case Enum.find(files, &(length(&1.path) <= level)) do
      nil -> :ok
      %{path: path} -> {:error, {:loose_file, display(path)}}
    end
  end

  # A skill is an immediate directory, whether it holds a manifest, some other
  # file, or nothing at all: an empty one is still a skill that was offered and
  # is missing its manifest.
  defp names(files, dirs, level) do
    from_files =
      for %{path: path} <- files, length(path) > level, do: Enum.at(path, level - 1)

    from_dirs = for path <- dirs, length(path) == level, do: List.last(path)

    Enum.uniq(from_files ++ from_dirs) |> Enum.sort()
  end

  defp collect_skill(files, base, name) do
    root = base ++ [name]

    if manifest?(files, root ++ [@manifest]) do
      {:ok, %{name: name, files: below(files, root)}}
    else
      {:error, {:missing_manifest, display(root)}}
    end
  end

  defp top_level(files), do: files |> Enum.map(&hd(&1.path)) |> Enum.uniq() |> Enum.sort()

  defp manifest?(files, path), do: Enum.any?(files, &(&1.path == path))

  # A skill's files at the paths they had inside it. A path the skill does not
  # hold cannot be dropped silently, so anything not below the root is left for
  # the layout checks to have refused already.
  defp below(files, root) do
    depth = length(root)

    for %{path: path} = file <- files,
        length(path) > depth,
        Enum.take(path, depth) == root do
      %{file | path: Enum.drop(path, depth)}
    end
  end

  # -- paths as the operator wrote them --

  defp relative([], name), do: name
  defp relative(prefix, name), do: Enum.join(prefix, "/") <> "/" <> name

  defp display([]), do: ""
  defp display(segments), do: Enum.join(segments, "/")
end
