defmodule AgentDb.ArchiveTest do
  @moduledoc """
  The bounded tar container two features share.

  Skill bundles and data-transfer archives both accept a tar file a user chose,
  and both are read through `AgentDb.Archive`. What is asserted here is the
  container's own contract: a bound that holds, and a refusal that happens
  before anything is read rather than after.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Archive

  @entries 500
  @bytes 5_000_000

  setup do
    dir = AgentDb.Test.Scratch.dir("archive")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  # Members are named by their path inside the archive and looked up from the
  # working directory, so the archive is written from where its members are.
  defp tar(dir, files, opts \\ []) do
    staging = Path.join(dir, "staging-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(staging)

    for {path, content} <- files do
      full = Path.join(staging, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    path = Path.join(dir, "a-#{:erlang.unique_integer([:positive])}.tar")

    :ok =
      File.cd!(staging, fn ->
        :ok =
          :erl_tar.create(
            String.to_charlist(path),
            Enum.map(files, fn {p, _} -> String.to_charlist(p) end),
            opts
          )
      end)

    File.read!(path)
  end

  defp gzipped(binary), do: :zlib.gzip(binary)

  # `:erl_tar` can only write to a path, so the writer builds in the system
  # temporary directory. A scratch file that outlives the call would accumulate
  # there on every export.
  defp scratch_files do
    System.tmp_dir!()
    |> Path.join("agent_db_archive_*.tar")
    |> Path.wildcard()
    |> Enum.sort()
  end

  describe "writing" do
    test "builds an archive a reader accepts, with every member intact" do
      assert {:ok, binary} = Archive.build([{"manifest.json", "{}"}, {"a/notes.md", "alpha\n"}])

      assert {:ok, members} = Archive.list(binary, @entries, @bytes)
      assert Enum.sort(Enum.map(members, & &1.name)) == ["a/notes.md", "manifest.json"]

      assert {:ok, extracted} = Archive.extract(binary, @bytes)
      assert extracted["a/notes.md"] == "alpha\n"
      assert extracted["manifest.json"] == "{}"
    end

    test "builds the same bytes whether the members are strings or charlists", %{dir: dir} do
      # The writer takes the names callers have, which are strings; the reader
      # hands back strings. One archive written both ways must be one archive.
      assert {:ok, written} = Archive.build([{"a/notes.md", "alpha\n"}])
      path = Path.join(dir, "same.tar")

      assert :ok = Archive.write(path, [{"a/notes.md", "alpha\n"}], false)
      assert File.read!(path) == written
    end

    test "writes a gzipped archive when asked, and a plain one otherwise", %{dir: dir} do
      plain = Path.join(dir, "plain.tar")
      packed = Path.join(dir, "packed.tar.gz")

      assert :ok = Archive.write(plain, [{"a/notes.md", "alpha\n"}], false)
      assert :ok = Archive.write(packed, [{"a/notes.md", "alpha\n"}], true)

      assert <<0x1F, 0x8B, _rest::binary>> = File.read!(packed)
      assert {:ok, [_member]} = Archive.list(File.read!(plain), @entries, @bytes)
      assert {:ok, [_member]} = Archive.list(File.read!(packed), @entries, @bytes)
    end

    test "creates the directories a destination needs", %{dir: dir} do
      path = Path.join([dir, "deeply", "nested", "out.tar"])

      assert :ok = Archive.write(path, [{"a/notes.md", "alpha\n"}], false)
      assert File.exists?(path)
    end

    test "leaves no scratch file behind", %{dir: dir} do
      before = scratch_files()

      assert {:ok, _binary} = Archive.build([{"a/notes.md", "alpha\n"}])
      assert {:error, _reason} = Archive.write(dir, [{"a/notes.md", "alpha\n"}], false)

      assert scratch_files() == before
    end
  end

  describe "digest" do
    test "is the lower-case hex SHA-256 the manifest records" do
      assert Archive.digest("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      assert Archive.digest("alpha") ==
               "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8"
    end

    test "changes with the content and is stable across calls" do
      digest = Archive.digest("alpha")

      assert digest == Archive.digest("alpha")
      refute digest == Archive.digest("beta")
    end
  end

  describe "listing" do
    test "reports every member with its type and size", %{dir: dir} do
      binary = tar(dir, [{"a/SKILL.md", "alpha\n"}, {"a/notes.md", "notes\n"}])

      assert {:ok, members} = Archive.list(binary, @entries, @bytes)
      assert length(members) == 2
      assert Enum.all?(members, &(&1.type == :regular))
      assert "a/SKILL.md" in Enum.map(members, & &1.name)
    end

    test "reads a gzip-compressed archive the same way", %{dir: dir} do
      binary = gzipped(tar(dir, [{"a/SKILL.md", "alpha\n"}]))

      assert {:ok, members} = Archive.list(binary, @entries, @bytes)
      assert [%{name: "a/SKILL.md", type: :regular}] = members
    end

    test "refuses more members than the bound allows", %{dir: dir} do
      binary = tar(dir, for(n <- 1..5, do: {"a/f#{n}.md", "x"}))

      assert {:error, {:too_many_entries, 3}} = Archive.list(binary, 3, @bytes)
    end

    test "refuses a total larger than the bound before reading it", %{dir: dir} do
      binary = tar(dir, [{"a/big.md", String.duplicate("x", 5_000)}])

      assert {:error, {:too_large, 1_000}} = Archive.list(binary, @entries, 1_000)
    end

    test "refuses bytes that are not a tar at all" do
      assert {:error, {:malformed_archive, _}} = Archive.list("not an archive", @entries, @bytes)
    end
  end

  describe "extraction" do
    test "returns the contents of every regular member", %{dir: dir} do
      binary = tar(dir, [{"a/SKILL.md", "alpha\n"}, {"a/notes.md", "notes\n"}])

      assert {:ok, contents} = Archive.extract(binary, @bytes)
      assert contents["a/SKILL.md"] == "alpha\n"
      assert contents["a/notes.md"] == "notes\n"
    end

    test "keys are text, not charlists", %{dir: dir} do
      binary = tar(dir, [{"a/SKILL.md", "alpha\n"}])

      assert {:ok, contents} = Archive.extract(binary, @bytes)

      for {name, _content} <- contents do
        assert is_binary(name)
      end
    end

    test "refuses a member larger than the read bound", %{dir: dir} do
      binary = tar(dir, [{"a/big.md", String.duplicate("x", 5_000)}])

      assert {:error, {:too_large, 100}} = Archive.extract(binary, 100)
    end
  end
end
