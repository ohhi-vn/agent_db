defmodule AgentDb.Application.DataTransfer.ManifestTest do
  @moduledoc """
  The transfer format, asked directly.

  `data_transfer_test.exs` holds the format's contract through the workflow that
  uses it: an export that round-trips and an import that refuses. This file asks
  the format module the same questions on its own, because it is now a module
  with an owner rather than a private section of a workflow, and a module with an
  owner is tested where it lives.

  What is asserted is the refusal and the acceptance, never the shape of an
  error tuple beyond the reason it names: the reasons are part of the workflow's
  public error taxonomy and are covered there.
  """
  use ExUnit.Case, async: true

  alias AgentDb.Application.DataTransfer.Manifest

  @limits %{max_entries: 100, max_bytes: 1_000_000}

  @documents [%{uri: "viking://resources/a.md", content: "hello", abstract: nil, overview: nil}]
  @memories [
    %{
      uri: "viking://user/memories/lang",
      assertions: [%{value: "elixir", confidence: 0.9, source: nil}]
    }
  ]
  @sessions [%{id: "s1", messages: [%{role: :user, content: "hi"}]}]

  describe "members" do
    test "are the four JSON members a transfer archive holds, in order" do
      assert [
               {"manifest.json", "m"},
               {"documents.json", "d"},
               {"memories.json", "me"},
               {"sessions.json", "s"}
             ] = Manifest.members("m", "d", "me", "s")
    end
  end

  describe "encoding" do
    test "round-trips the three collections through their JSON members" do
      assert {:ok, {documents, memories, sessions}} =
               Manifest.encode_payload(@documents, @memories, @sessions)

      assert Jason.decode!(documents) == [
               %{
                 "uri" => "viking://resources/a.md",
                 "content" => "hello",
                 "abstract" => nil,
                 "overview" => nil
               }
             ]

      assert [%{"assertions" => [%{"value" => "elixir"}]}] = Jason.decode!(memories)
      assert [%{"id" => "s1"}] = Jason.decode!(sessions)
    end

    test "the manifest records the scope, the counts, and a checksum per member" do
      assert {:ok, {documents, memories, sessions}} =
               Manifest.encode_payload(@documents, @memories, @sessions)

      assert {:ok, json} =
               Manifest.encode(
                 "viking://resources",
                 @documents,
                 @memories,
                 @sessions,
                 documents,
                 memories,
                 sessions
               )

      manifest = Jason.decode!(json)

      assert manifest["format_version"] == Manifest.format_version()
      assert manifest["scope"] == "viking://resources"

      assert manifest["counts"] == %{
               "documents" => 1,
               "memories" => 1,
               "sessions" => 1,
               "messages" => 1
             }

      assert is_integer(manifest["exported_at"])

      assert Map.keys(manifest["checksums"]) |> Enum.sort() == [
               "documents",
               "memories",
               "sessions"
             ]
    end

    test "a full export's scope is nil rather than absent" do
      assert {:ok, {documents, memories, sessions}} =
               Manifest.encode_payload(@documents, @memories, @sessions)

      assert {:ok, json} =
               Manifest.encode(
                 nil,
                 @documents,
                 @memories,
                 @sessions,
                 documents,
                 memories,
                 sessions
               )

      assert Jason.decode!(json)["scope"] == nil
    end
  end

  describe "bounds" do
    test "refuses a payload holding more entries than the limit allows" do
      documents =
        for(
          n <- 1..101,
          do: %{uri: "viking://r/#{n}", content: "x", abstract: nil, overview: nil}
        )

      assert {:error, {:too_many_entries, 100}} =
               Manifest.check_counts(documents, [], [], @limits)
    end

    test "refuses encoded members larger than the byte limit allows" do
      big = String.duplicate("x", 2_000)

      assert {:error, {:too_large, 1_000}} =
               Manifest.check_bytes(big, "", "", %{@limits | max_bytes: 1_000})
    end

    test "refuses a binary larger than the byte limit allows, before it is expanded" do
      assert :ok = Manifest.check_size(999, %{@limits | max_bytes: 1_000})

      assert {:error, {:too_large, 1_000}} =
               Manifest.check_size(1_001, %{@limits | max_bytes: 1_000})
    end
  end

  describe "members the archive must hold" do
    test "accepts exactly the four members" do
      members = Manifest.members("{}", "[]", "[]", "[]")

      assert :ok = Manifest.check_members(members, @limits)
    end

    test "refuses a missing member" do
      members =
        Manifest.members("{}", "[]", "[]", "[]") |> Enum.reject(&match?({"sessions.json", _}, &1))

      assert {:error, {:missing_member, "sessions.json"}} =
               Manifest.check_members(members, @limits)
    end

    test "refuses a member the format does not define" do
      members = Manifest.members("{}", "[]", "[]", "[]") ++ [{"extra.json", "{}"}]

      assert {:error, {:unexpected_entry, "extra.json"}} =
               Manifest.check_members(members, @limits)
    end

    test "refuses a name that would escape the archive root" do
      # A name outside the four is refused as an unexpected entry, and that
      # check runs first: the path-escape clause behind it is a backstop for a
      # future where the member set is not a fixed list of constants, not a
      # separately reachable outcome.
      for name <- ["/etc/passwd", "../outside.json", "a\\b.json"] do
        members = Manifest.members("{}", "[]", "[]", "[]") ++ [{name, "[]"}]

        assert {:error, {:unexpected_entry, ^name}} = Manifest.check_members(members, @limits)
      end
    end
  end

  describe "validation" do
    setup do
      assert {:ok, {documents, memories, sessions}} =
               Manifest.encode_payload(@documents, @memories, @sessions)

      assert {:ok, manifest} =
               Manifest.encode(
                 nil,
                 @documents,
                 @memories,
                 @sessions,
                 documents,
                 memories,
                 sessions
               )

      members = Manifest.members(manifest, documents, memories, sessions)

      {:ok, decoded} = Manifest.decode(members)
      %{decoded: decoded}
    end

    test "accepts an archive it just encoded", %{decoded: decoded} do
      assert {:ok, payload} = Manifest.validate_payload(decoded, @limits)
      assert payload.documents == @documents
      assert payload.memories == @memories

      # Each message comes back stamped with its position, which is the order
      # the store replays it in.
      assert [%{id: "s1", messages: [%{seq: 0, role: :user, content: "hi"}]}] = payload.sessions
    end

    test "refuses a manifest whose counts disagree with what it carries", %{decoded: decoded} do
      manifest = put_in(decoded.manifest, ["counts", "documents"], 7)

      assert {:error, {:count_mismatch, "documents"}} =
               Manifest.validate_payload(%{decoded | manifest: manifest}, @limits)
    end

    test "refuses a member whose bytes no longer match its checksum", %{decoded: decoded} do
      tampered =
        put_in(
          decoded.raw,
          ["documents.json"],
          ~s([{"uri":"viking://r/x.md","content":"changed"}])
        )

      assert {:error, {:checksum_mismatch, "documents.json"}} =
               Manifest.validate_payload(%{decoded | raw: tampered}, @limits)
    end

    test "refuses a format version it does not read", %{decoded: decoded} do
      manifest = put_in(decoded.manifest, ["format_version"], Manifest.format_version() + 1)

      assert {:error, {:unsupported_version, _}} =
               Manifest.validate_payload(%{decoded | manifest: manifest}, @limits)
    end

    test "refuses a document that is not an object with a URI and content", %{decoded: decoded} do
      assert {:error, {:invalid_document, _}} =
               Manifest.validate_payload(%{decoded | documents: ["not a document"]}, @limits)
    end

    test "refuses a document at the root URI", %{decoded: decoded} do
      root = [%{"uri" => "viking://", "content" => "x"}]

      assert {:error, {:invalid_document, detail}} =
               Manifest.validate_payload(%{decoded | documents: root}, @limits)

      assert detail =~ "root"
    end

    test "refuses a memory whose assertions are empty", %{decoded: decoded} do
      empty = [%{"uri" => "viking://user/memories/lang", "assertions" => []}]

      assert {:error, {:invalid_memory, _}} =
               Manifest.validate_payload(%{decoded | memories: empty}, @limits)
    end

    test "refuses a confidence outside 0..1", %{decoded: decoded} do
      out_of_range = [
        %{
          "uri" => "viking://user/memories/lang",
          "assertions" => [%{"value" => "elixir", "confidence" => 1.5}]
        }
      ]

      assert {:error, {:invalid_memory, _}} =
               Manifest.validate_payload(%{decoded | memories: out_of_range}, @limits)
    end

    test "refuses a session message with a role the store does not hold", %{decoded: decoded} do
      bad_role = [%{"id" => "s1", "messages" => [%{"role" => "system", "content" => "hi"}]}]
      other_role = [%{"id" => "s1", "messages" => [%{"role" => "moderator", "content" => "hi"}]}]

      # "system" is a role the store keeps; an invented one is not.
      assert {:ok, _payload} =
               Manifest.validate_payload(%{decoded | sessions: bad_role}, %{
                 @limits
                 | max_bytes: 10_000_000
               })

      assert {:error, {:invalid_session, _}} =
               Manifest.validate_payload(%{decoded | sessions: other_role}, @limits)
    end

    test "refuses members that are not valid JSON", %{decoded: _decoded} do
      assert {:error, {:invalid_json, "documents.json"}} =
               Manifest.decode(Manifest.members("{}", "{not json", "[]", "[]"))
    end
  end
end
