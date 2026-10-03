defmodule AgentDb.Skills.SourceTest do
  @moduledoc """
  What counts as an importable Agent Skills bundle.

  The source is the one place that decides, so it is tested on its own rather
  than through an import: a bundle is either read as a set of skills or refused
  with a reason the operator can act on, and these assertions are about which of
  those two happens.
  """
  use ExUnit.Case, async: true

  alias AgentDb.Skills.Source

  @manifest "# Skill\n\nWhat it does.\n"

  describe "a folder holding one skill" do
    test "is read as that skill, named after the folder it was read from" do
      folder = tmp("one")

      write(folder, "SKILL.md", @manifest)
      write(folder, "references/guide.md", "the guide\n")
      write(folder, "scripts/check.py", "print('ok')\n")

      assert {:ok, [%{name: "one", files: files}]} = Source.load({:path, folder})

      assert Enum.map(files, & &1.path) == [
               ["SKILL.md"],
               ["references", "guide.md"],
               ["scripts", "check.py"]
             ]

      assert Enum.find(files, &(&1.path == ["SKILL.md"])).content == @manifest
    end

    test "a skill directory inside a folder is read as that skill" do
      folder = tmp("holder")
      write(folder, "one/SKILL.md", @manifest)
      write(folder, "one/guide.md", "the guide\n")

      assert {:ok, [%{name: "one", files: files}]} = Source.load({:path, folder})
      assert Enum.map(files, & &1.path) == [["SKILL.md"], ["guide.md"]]
    end

    test "keeps content byte for byte" do
      folder = tmp("verbatim")
      write(folder, "SKILL.md", @manifest)
      write(folder, "notes.md", "trailing spaces  \r\nand a tab\there\n")

      assert {:ok, [%{files: files}]} = Source.load({:path, folder})

      assert Enum.find(files, &(&1.path == ["notes.md"])).content ==
               "trailing spaces  \r\nand a tab\there\n"
    end
  end

  describe "a folder holding a collection" do
    test "is read as one skill per immediate directory" do
      folder = tmp("collection")

      write(folder, "alpha/SKILL.md", "alpha manifest\n")
      write(folder, "alpha/references/guide.md", "alpha guide\n")
      write(folder, "beta/SKILL.md", "beta manifest\n")

      assert {:ok, skills} = Source.load({:path, folder})

      assert Enum.map(skills, & &1.name) == ["alpha", "beta"]
      assert Enum.map(hd(skills).files, & &1.path) == [["SKILL.md"], ["references", "guide.md"]]
    end

    test "an empty skill directory is reported as a skill without its manifest" do
      folder = tmp("empty-skill")
      write(folder, "alpha/SKILL.md", "alpha\n")
      File.mkdir_p!(Path.join(folder, "beta"))

      assert {:error, {:missing_manifest, "beta"}} = Source.load({:path, folder})
      assert Source.message({:missing_manifest, "beta"}) =~ "SKILL.md"
    end

    test "a file where a skill directory belongs is reported by name" do
      folder = tmp("loose")
      write(folder, "alpha/SKILL.md", "alpha\n")
      write(folder, "readme.md", "not a skill\n")

      assert {:error, {:loose_file, "readme.md"}} = Source.load({:path, folder})
    end

    test "a folder with no files is reported rather than imported as nothing" do
      assert {:error, {:no_skills}} = Source.load({:path, tmp("nothing")})
    end
  end

  describe "a source that cannot be stored as it is" do
    test "a symbolic link is refused rather than followed" do
      folder = tmp("link")
      write(folder, "alpha/SKILL.md", "alpha\n")
      File.ln_s!(Path.join(folder, "alpha/SKILL.md"), Path.join(folder, "alpha/linked.md"))

      assert {:error, {:unsupported_entry, :symlink, "alpha/linked.md"}} =
               Source.load({:path, folder})
    end

    test "a link where the source itself belongs is refused" do
      folder = tmp("source-link")
      write(folder, "alpha/SKILL.md", "alpha\n")
      link = Path.join(tmp("links"), "link")
      File.ln_s!(folder, link)

      assert {:error, {:unsupported_source, :symlink, ^link}} = Source.load({:path, link})
    end

    test "a file that is not UTF-8 is reported, not mangled" do
      folder = tmp("binary")
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "SKILL.md"), <<"---\n", 0xFF, 0xFE, "\n---\n">>)

      assert {:error, {:invalid_utf8, "SKILL.md"}} = Source.load({:path, folder})
      assert Source.message({:invalid_utf8, "SKILL.md"}) =~ "UTF-8"
    end

    test "a path that does not exist is reported" do
      path = Path.join(root(), "never-written")

      assert {:error, {:unreadable_source, :enoent, ^path}} = Source.load({:path, path})
    end
  end

  describe "an archive" do
    test "is read as the skills it holds" do
      archive =
        archive([{"skills/alpha/SKILL.md", "alpha\n"}, {"skills/beta/SKILL.md", "beta\n"}])

      assert {:ok, skills} = Source.load({:path, archive})
      assert Enum.map(skills, & &1.name) == ["alpha", "beta"]
    end

    test "gzip-compressed is read the same way" do
      path =
        gzipped_archive(
          [{"alpha/SKILL.md", "alpha\n"}, {"alpha/references/guide.md", "g\n"}],
          "skills.tar.gz"
        )

      assert {:ok, [%{name: "alpha", files: files}]} = Source.load({:path, path})
      assert Enum.map(files, & &1.path) == [["SKILL.md"], ["references", "guide.md"]]
    end

    test "a single enclosing directory is recognised as a wrapper" do
      archive =
        archive([{"my-repo/alpha/SKILL.md", "alpha\n"}, {"my-repo/beta/SKILL.md", "beta\n"}])

      assert {:ok, skills} = Source.load({:path, archive})
      assert Enum.map(skills, & &1.name) == ["alpha", "beta"]
    end

    test "an archive of one skill is not unwrapped" do
      archive = archive([{"alpha/SKILL.md", "alpha\n"}, {"alpha/guide.md", "guide\n"}])

      assert {:ok, [%{name: "alpha", files: files}]} = Source.load({:path, archive})
      assert Enum.map(files, & &1.path) == [["SKILL.md"], ["guide.md"]]
    end

    test "a member whose path traverses is refused" do
      archive = archive([{"alpha/SKILL.md", "alpha\n"}, {"../escaped.md", "nope\n"}])

      assert {:error, {:unsafe_path, "../escaped.md", :traversal}} = Source.load({:path, archive})
    end

    test "an absolute member is refused" do
      archive = archive([{"alpha/SKILL.md", "alpha\n"}, {"/etc/passwd", "root\n"}])

      assert {:error, {:unsafe_path, "/etc/passwd", :absolute}} = Source.load({:path, archive})
    end

    test "a backslashed member is refused" do
      archive = archive([{"alpha/SKILL.md", "alpha\n"}, {"alpha\\windows.md", "nope\n"}])

      assert {:error, {:unsafe_path, "alpha\\windows.md", :backslash}} =
               Source.load({:path, archive})
    end

    test "a member with a control character is refused" do
      archive = archive([{"alpha/SKILL.md", "alpha\n"}, {"alpha/bad.md", "nope\n"}])

      assert {:error, {:unsafe_path, _, :control_character}} = Source.load({:path, archive})
    end

    test "a member stored as both a file and a directory is refused" do
      archive = tar([member("alpha", "a file\n"), member("alpha/SKILL.md", "alpha\n")])

      assert {:error, {:path_conflict, "alpha"}} = Source.load({:path, archive})
    end

    test "a member stored twice is refused rather than imported twice" do
      archive = archive([{"alpha/SKILL.md", "one\n"}, {"alpha/SKILL.md", "two\n"}])

      assert {:error, {:duplicate_path, "alpha/SKILL.md"}} = Source.load({:path, archive})
    end

    test "a link member is refused" do
      archive = link_archive("alpha/linked.md", "alpha/SKILL.md")

      assert {:error, {:unsupported_entry, :symlink, "alpha/linked.md"}} =
               Source.load({:path, archive})
    end

    test "a hard-link member is refused" do
      archive = hard_link_archive("alpha/linked.md", "alpha/SKILL.md")

      assert {:error, {:unsupported_entry, :link, "alpha/linked.md"}} =
               Source.load({:path, archive})
    end

    test "bytes that are not an archive are reported as a malformed archive" do
      path = tmp_path("broken.tar")
      File.write!(path, "this is not a tar archive")

      assert {:error, {:malformed_archive, _reason}} = Source.load({:path, path})
    end
  end

  describe "a browser directory selection" do
    test "is read the same way as the folder it came from" do
      uploads = [
        %{path: "my-skills/alpha/SKILL.md", content: "alpha\n"},
        %{path: "my-skills/alpha/guide.md", content: "guide\n"},
        %{path: "my-skills/beta/SKILL.md", content: "beta\n"}
      ]

      assert {:ok, skills} = Source.load({:uploads, uploads})
      assert Enum.map(skills, & &1.name) == ["alpha", "beta"]
      assert Enum.map(hd(skills).files, & &1.path) == [["SKILL.md"], ["guide.md"]]
    end

    test "archive bytes are read the same way as the archive on disk" do
      uploads = [%{path: "alpha/SKILL.md", content: "alpha\n"}]
      {:ok, [skill]} = Source.load({:uploads, uploads})

      assert {:ok, [from_disk]} = Source.load({:path, archive([{"alpha/SKILL.md", "alpha\n"}])})
      assert skill == from_disk
    end

    test "a path with an empty segment is refused" do
      uploads = [
        %{path: "alpha/SKILL.md", content: "alpha\n"},
        %{path: "alpha//x.md", content: "x\n"}
      ]

      assert {:error, {:unsafe_path, "alpha//x.md", :empty_segment}} =
               Source.load({:uploads, uploads})
    end

    test "a traversing path from the browser is refused" do
      uploads = [
        %{path: "alpha/SKILL.md", content: "alpha\n"},
        %{path: "../outside.md", content: "nope\n"}
      ]

      assert {:error, {:unsafe_path, "../outside.md", :traversal}} =
               Source.load({:uploads, uploads})
    end

    test "an uploaded file that is not UTF-8 is refused" do
      assert {:error, {:invalid_utf8, "alpha/SKILL.md"}} =
               Source.load({:uploads, [%{path: "alpha/SKILL.md", content: <<0xFF, 0xFE>>}]})
    end

    test "an empty selection is reported rather than imported as nothing" do
      assert {:error, {:no_skills}} = Source.load({:uploads, []})
    end
  end

  describe "the limits" do
    test "are published, so a caller configures its own caps to match" do
      assert %{max_entries: entries, max_bytes: bytes} = Source.limits()
      assert entries > 0 and bytes > 0
    end

    test "refuse a source with too many entries" do
      uploads =
        for index <- 1..(Source.limits().max_entries + 1) do
          %{path: "alpha/#{index}.md", content: "x"}
        end

      assert {:error, {:too_many_entries, limit}} = Source.load({:uploads, uploads})
      assert limit == Source.limits().max_entries
    end

    test "refuse a source past the byte limit" do
      oversized = String.duplicate("x", Source.limits().max_bytes + 1)

      assert {:error, {:too_large, limit}} =
               Source.load({:uploads, [%{path: "alpha/SKILL.md", content: oversized}]})

      assert limit == Source.limits().max_bytes
    end

    test "refuse an archive whose members add up past the byte limit" do
      # Each member is inside the limit; it is the bundle that is not, and the
      # listing refuses it before any of it is expanded.
      third = div(Source.limits().max_bytes, 2) + 1
      members = for index <- 1..3, do: {"alpha/#{index}.md", String.duplicate("x", third)}

      assert {:error, {:too_large, limit}} = Source.load({:path, archive(members)})
      assert limit == Source.limits().max_bytes
    end

    test "refuse an archive that expands past the byte limit, however small it is" do
      # Far under the compressed limit, well over it once expanded: bounded while
      # it is inflated, not after.
      path =
        gzipped_archive(
          [{"alpha/SKILL.md", String.duplicate("x", Source.limits().max_bytes + 1)}],
          "inflating.tar.gz"
        )

      assert {:error, {:too_large, limit}} = Source.load({:path, path})
      assert limit == Source.limits().max_bytes
    end

    test "refuse a gzip that is not a complete stream" do
      truncated = archive([{"alpha/SKILL.md", "alpha\n"}]) |> File.read!() |> gzipped()
      truncated = binary_part(truncated, 0, 12)
      path = tmp_path("truncated.tar.gz")
      File.write!(path, truncated)

      assert {:error, {:malformed_archive, _reason}} = Source.load({:path, path})
    end
  end

  # -- archives, built so the test depends on no system tar --

  # A tar holding exactly the members given, named by their paths inside it.
  defp archive(members) do
    staging = tmp("staging")

    for {name, content} <- members do
      write(staging, name, content)
    end

    create(staging, Enum.map(members, fn {name, _content} -> name end), "skills.tar")
  end

  # An archive written member by member, for the names a filesystem cannot hold.
  defp tar(members) do
    path = tmp_path("handwritten.tar")
    File.write!(path, IO.iodata_to_binary(members) <> :binary.copy(<<0>>, 1024))
    path
  end

  # A gzip-compressed archive holding the members given.
  defp gzipped_archive(members, name) do
    path = tmp_path(name)
    File.write!(path, gzipped(File.read!(archive(members))))
    path
  end

  # An archive holding a symbolic link, which Erlang's writer stores as one
  # unless asked to follow it.
  defp link_archive(link_name, target) do
    staging = tmp("link-staging")
    write(staging, "alpha/SKILL.md", "alpha\n")
    link = Path.join(staging, link_name)
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(Path.join(staging, target), link)

    create(staging, [link_name], "linked.tar")
  end

  # An archive holding a hard link, which Erlang's writer never stores: a member
  # whose typeflag names a target rather than carrying bytes of its own.
  defp hard_link_archive(link_name, target) do
    tar([member("alpha/SKILL.md", "alpha\n"), member(link_name, "", "1", target)])
  end

  defp member(name, data, typeflag \\ "0", linkname \\ "") do
    field = fn text, size -> text <> :binary.copy(<<0>>, size - byte_size(text)) end

    body =
      field.(name, 100) <>
        field.("0000644", 8) <>
        field.("0000000", 8) <>
        field.("0000000", 8) <>
        field.(Integer.to_string(byte_size(data), 8), 12) <>
        field.("00000000000", 12) <>
        "        " <>
        typeflag <>
        field.(linkname, 100) <>
        "ustar\0" <>
        "00" <>
        field.("agent_db", 32) <>
        field.("agent_db", 32) <>
        field.("0000000", 8) <>
        field.("0000000", 8) <>
        field.("", 155)

    # The checksum is the sum of the block with its own field read as spaces, so
    # it is placed last, over every other byte.
    checksum = body |> :binary.bin_to_list() |> Enum.sum()

    header =
      <<binary_part(body, 0, 148)::binary, field.(Integer.to_string(checksum, 8), 8)::binary,
        binary_part(body, 156, 344)::binary, 0::size(96)>>

    remainder = rem(byte_size(data), 512)
    header <> data <> :binary.copy(<<0>>, 512 - remainder)
  end

  defp gzipped(tar), do: :zlib.gzip(tar)

  # Members are named by their path inside the archive, and a name is looked up
  # from the working directory, so the archive is written from where its members
  # are and named by the path it will be read from.
  defp create(staging, names, name) do
    path = Path.join(tmp("archives"), name)

    :ok =
      File.cd!(staging, fn ->
        :erl_tar.create(String.to_charlist(path), Enum.map(names, &String.to_charlist/1))
      end)

    path
  end

  # -- folders --

  # A folder whose own name is `name`: a source read from it takes its skill's
  # name from it, so the name has to be the one the test wrote.
  defp tmp(name) do
    path = Path.join(root(), name)
    File.mkdir_p!(path)
    path
  end

  # A path inside a fresh temporary directory, for a file to be written to.
  defp tmp_path(name), do: Path.join(tmp("files"), name)

  # A fresh temporary directory per call, so nothing two calls make can
  # collide -- including with a previous run's, which replayed the same
  # `unique_integer` sequence.
  defp root, do: AgentDb.Test.Scratch.dir("agent_db_source")

  defp write(folder, relative, content) do
    path = Path.join(folder, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
