defmodule AgentDb.DataTransferTest do
  @moduledoc """
  Portable export/import of store data as a tar archive.

  What an export carries, what an import restores, and what a refused
  archive leaves alone. Store behaviour after import (search, navigation,
  notifications) is asserted here because an import that is not readable
  through the ordinary operations has not restored anything.
  """
  use ExUnit.Case, async: false

  alias AgentDb.Application.DataTransfer
  alias AgentDb.Cache

  setup do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()

    on_exit(fn -> Application.delete_env(:agent_db, :data_dir) end)

    :ok
  end

  describe "codec (export_payload / parse_archive)" do
    test "round-trips a payload without a store" do
      payload = %{
        documents: [
          %{uri: "viking://resources/a.md", content: "hello", abstract: "L0", overview: nil}
        ],
        memories: [
          %{
            uri: "viking://user/memories/preferences/lang",
            assertions: [%{value: "elixir", confidence: 0.9, source: nil}]
          }
        ],
        sessions: [%{id: "s1", messages: [%{role: "user", content: "hi"}]}],
        scope: nil
      }

      assert {:ok, archive} = DataTransfer.export_payload(payload)
      assert {:ok, parsed} = DataTransfer.parse_archive({:archive, archive})

      assert hd(parsed.documents).uri == "viking://resources/a.md"
      assert hd(parsed.documents).content == "hello"
      assert hd(parsed.memories).uri == "viking://user/memories/preferences/lang"
      assert hd(parsed.sessions).id == "s1"
    end

    test "refuses a traversal member whole" do
      {:ok, archive} = DataTransfer.export_payload(empty_payload())
      traversal = traversal_archive(archive)

      assert {:error, reason} = DataTransfer.parse_archive({:archive, traversal})
      assert DataTransfer.message(reason) =~ "unexpected"
    end

    test "refuses random bytes without side effects" do
      before = store_snapshot()

      assert {:error, reason} =
               DataTransfer.parse_archive({:archive, :crypto.strong_rand_bytes(128)})

      assert DataTransfer.message(reason) =~ "could not be read"

      assert store_snapshot() == before
    end

    test "refuses an oversize archive before expansion" do
      big = String.duplicate("x", DataTransfer.limits().max_bytes + 1)

      payload = %{
        documents: [
          %{uri: "viking://resources/big.md", content: big, abstract: nil, overview: nil}
        ],
        memories: [],
        sessions: [],
        scope: nil
      }

      assert {:error, {:too_large, _}} = DataTransfer.export_payload(payload)
    end

    test "refuses a manifest with a newer version" do
      {:ok, archive} = DataTransfer.export_payload(empty_payload())
      bumped = bump_manifest_version(archive, 99)

      assert {:error, {:unsupported_version, 99}} = DataTransfer.parse_archive({:archive, bumped})
    end

    test "refuses a missing member" do
      {:ok, archive} = DataTransfer.export_payload(empty_payload())
      without = drop_member(archive, "sessions.json")

      assert {:error, {:missing_member, "sessions.json"}} =
               DataTransfer.parse_archive({:archive, without})
    end

    test "refuses an archive holding a link" do
      before = store_snapshot()
      {:ok, archive} = DataTransfer.export_payload(empty_payload())
      linked = symlink_archive(archive)

      assert {:error, {:unsupported_entry, :symlink, "escape.md"}} =
               DataTransfer.parse_archive({:archive, linked})

      assert DataTransfer.message({:unsupported_entry, :symlink, "escape.md"}) =~ "escape.md"

      # The refusal happens before anything is written, so an import that
      # carried a link did not land part of the archive either.
      assert store_snapshot() == before
    end
  end

  describe "error_message/1" do
    test "renders every refusal as a sentence" do
      reasons = [
        :not_found,
        {:invalid_scope, "nope"},
        {:no_such_scope, "viking://resources/missing"},
        {:unreadable_source, :enoent, "/tmp/missing.tar"},
        {:malformed_archive, :bad},
        {:too_many_entries, 10_000},
        {:too_large, 50_000_000},
        {:missing_member, "manifest.json"},
        {:unexpected_entry, "../escape.md"},
        {:duplicate_entry, "manifest.json"},
        {:invalid_manifest, "nope"},
        {:unsupported_version, 99},
        {:checksum_mismatch, "documents.json"},
        {:count_mismatch, "documents"},
        {:invalid_document, "bad"},
        {:invalid_memory, "bad"},
        {:invalid_session, "bad"},
        {:invalid_json, "documents.json"},
        {:session_conflict, "s1"},
        {:import_failed, [{"u", :bad}]}
      ]

      for reason <- reasons do
        message = DataTransfer.message(reason)
        assert is_binary(message) and byte_size(message) > 0, "no message for #{inspect(reason)}"
      end
    end
  end

  describe "export" do
    test "writes a valid tar whose manifest counts match" do
      seed_store!()
      path = tmp_tar("full.tar.gz")

      assert {:ok, result} = AgentDb.export_data(path)
      assert File.exists?(path)
      assert result.documents >= 2
      assert result.memories == 1
      assert result.sessions == 1

      assert {:ok, parsed} = DataTransfer.parse_archive({:path, path})
      assert length(parsed.documents) == result.documents
      assert length(parsed.memories) == result.memories
      assert length(parsed.sessions) == result.sessions
    end

    test "a scoped export contains only the subtree" do
      seed_store!()
      path = tmp_tar("scoped.tar")

      assert {:ok, _} =
               AgentDb.export_data(path, scope: "viking://resources/project")

      assert {:ok, parsed} = DataTransfer.parse_archive({:path, path})

      assert Enum.all?(
               parsed.documents,
               &String.starts_with?(&1.uri, "viking://resources/project")
             )

      assert parsed.sessions == []
    end

    test "a missing scope fails without creating a file" do
      path = tmp_tar("missing.tar")

      assert {:error, {:no_such_scope, _}} =
               AgentDb.export_data(path, scope: "viking://resources/nope")

      refute File.exists?(path)
    end
  end

  describe "import" do
    test "round-trips documents, memories, and sessions into an empty store" do
      seed_store!()
      sid = session_id()
      path = tmp_tar("roundtrip.tar.gz")
      assert {:ok, _} = AgentDb.export_data(path)

      restart_fresh!()

      assert {:ok, result} = AgentDb.import_data(path)
      assert result.documents >= 2
      assert result.memories == 1
      assert result.sessions == 1

      assert {:ok, "# Project"} = AgentDb.read("viking://resources/project/readme.md")
      assert {:ok, "Project overview"} = AgentDb.abstract("viking://resources/project/readme.md")

      assert {:ok, [memory]} = AgentDb.recall("viking://user/memories/preferences/language")
      assert memory.value == "prefers Elixir"
      assert memory.confidence == 0.9

      assert {:ok, messages} = AgentDb.Application.Sessions.get(sid)
      assert Enum.map(messages, & &1.content) == ["Remember this", "Got it"]
    end

    test "merges without deleting unrelated data" do
      seed_store!()
      path = tmp_tar("merge.tar")
      assert {:ok, _} = AgentDb.export_data(path, scope: "viking://resources/project")

      assert :ok = AgentDb.write("viking://resources/unrelated.md", "stays")
      assert {:ok, _} = AgentDb.import_data(path)

      assert {:ok, "stays"} = AgentDb.read("viking://resources/unrelated.md")
      assert {:ok, "# Project"} = AgentDb.read("viking://resources/project/readme.md")
    end

    test "re-import converges without duplication" do
      seed_store!()
      path = tmp_tar("converge.tar")
      assert {:ok, _} = AgentDb.export_data(path)

      assert {:ok, first} = AgentDb.import_data(path)
      snapshot = store_snapshot()
      assert {:ok, second} = AgentDb.import_data(path)

      assert first.documents == second.documents
      assert store_snapshot() == snapshot
    end

    test "a refused archive leaves the store exactly as it was" do
      seed_store!()
      before = store_snapshot()

      assert {:error, _} = AgentDb.import_data({:archive, :crypto.strong_rand_bytes(64)})

      assert store_snapshot() == before
    end

    test "a conflicting session is skipped, not overwritten" do
      seed_store!()
      path = tmp_tar("conflict.tar.gz")
      assert {:ok, _} = AgentDb.export_data(path)

      # Diverge the live session from the exported one.
      assert :ok = AgentDb.append_message(session_id(), :user, "a new message")

      assert {:ok, result} = AgentDb.import_data(path)
      assert session_id() in result.skipped_sessions

      assert {:ok, messages} = AgentDb.Application.Sessions.get(session_id())
      assert List.last(messages).content == "a new message"
    end
  end

  describe "imported content behaves natively" do
    test "is searchable, findable, and notifies subscribers" do
      seed_store!()
      path = tmp_tar("native.tar")
      assert {:ok, _} = AgentDb.export_data(path)
      restart_fresh!()

      :ok = AgentDb.subscribe("viking://resources/project")
      assert {:ok, _} = AgentDb.import_data(path)

      assert {:ok, [_ | _]} =
               AgentDb.search("Project", mode: :keyword, scope: "viking://resources/project")

      assert {:ok, [_ | _]} = AgentDb.find("readme", scope: "viking://resources/project")
      assert {:ok, [_ | _]} = AgentDb.grep("Project", scope: "viking://resources/project")

      assert_receive {:context_changed, "viking://resources/project/readme.md", :written,
                      _version},
                     1_000
    end
  end

  # -- helpers --

  defp empty_payload do
    %{documents: [], memories: [], sessions: [], scope: nil}
  end

  defp seed_store! do
    :ok =
      AgentDb.write("viking://resources/project/readme.md", "# Project",
        abstract: "Project overview"
      )

    :ok = AgentDb.write("viking://resources/other.md", "other content")

    {:ok, _} =
      AgentDb.remember("viking://user/memories/preferences/language", "prefers Elixir",
        confidence: 0.9,
        source: "seed"
      )

    {:ok, sid} = AgentDb.create_session()
    Process.put(:seed_session, sid)
    :ok = AgentDb.append_message(sid, :user, "Remember this")
    :ok = AgentDb.append_message(sid, :assistant, "Got it")
    :ok
  end

  defp session_id, do: Process.get(:seed_session)

  defp store_snapshot do
    docs =
      case AgentDb.find("md", limit: 200) do
        {:ok, hits} -> Enum.map(hits, & &1.uri) |> Enum.sort()
        _ -> []
      end

    {:ok, memories} = AgentDb.recall(include_superseded: true)
    {docs, Enum.map(memories, &{&1.uri, &1.value, &1.status}) |> Enum.sort()}
  end

  defp tmp_tar(name) do
    dir = AgentDb.Test.Scratch.dir("agent_db_transfer")
    File.mkdir_p!(dir)
    Path.join(dir, name)
  end

  defp restart_app do
    :ok = Application.stop(:agent_db)
    {:ok, _} = Application.ensure_all_started(:agent_db)
    :ok
  end

  defp restart_fresh! do
    Cache.clear()
    Application.put_env(:agent_db, :data_dir, AgentDb.Config.test_data_dir())
    restart_app()
    Process.delete(:seed_session)
  end

  defp traversal_archive(archive) do
    {:ok, members} = :erl_tar.extract({:binary, archive}, [:memory])
    evil = members ++ [{~c"../escape.md", "nope"}]
    path = tmp_tar("evil.tar")

    :ok = :erl_tar.create(String.to_charlist(path), evil, [])
    File.read!(path)
  end

  # An archive with a symbolic link member, built the way a user's tar would
  # produce one. `:erl_tar.create/3` writes a link entry only when the path it
  # is given is a link on disk, so the members are staged first and the tar is
  # built from their names.
  defp symlink_archive(archive) do
    {:ok, members} = :erl_tar.extract({:binary, archive}, [:memory])
    path = tmp_tar("link.tar")
    staging = Path.dirname(path)

    for {name, content} <- members do
      full = Path.join(staging, List.to_string(name))
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    :ok = File.ln_s("payload", Path.join(staging, "escape.md"))
    on_exit(fn -> File.rm_rf!(staging) end)

    :ok =
      File.cd!(staging, fn ->
        :erl_tar.create(
          String.to_charlist(path),
          Enum.map(members, fn {name, _} -> name end) ++ [~c"escape.md"],
          []
        )
      end)

    File.read!(path)
  end

  defp bump_manifest_version(archive, version) do
    {:ok, members} = :erl_tar.extract({:binary, archive}, [:memory])
    by_name = Map.new(members, fn {name, content} -> {List.to_string(name), content} end)

    manifest =
      by_name["manifest.json"]
      |> Jason.decode!()
      |> Map.put("format_version", version)
      |> Jason.encode!()

    members =
      Enum.map(members, fn {name, content} ->
        if List.to_string(name) == "manifest.json", do: {name, manifest}, else: {name, content}
      end)

    path = tmp_tar("bumped.tar")
    :ok = :erl_tar.create(String.to_charlist(path), members, [])
    File.read!(path)
  end

  defp drop_member(archive, name) do
    {:ok, members} = :erl_tar.extract({:binary, archive}, [:memory])
    kept = Enum.reject(members, fn {member, _} -> List.to_string(member) == name end)
    path = tmp_tar("dropped.tar")
    :ok = :erl_tar.create(String.to_charlist(path), kept, [])
    File.read!(path)
  end
end
