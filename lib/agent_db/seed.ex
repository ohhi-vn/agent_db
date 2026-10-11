defmodule AgentDb.Seed do
  @moduledoc """
  Deterministic demo dataset for development and test environments.

  One command builds the same baseline everywhere: documents under a demo
  prefix, one typed memory per taxonomy type, one session committed into the
  tree, one demo skill, and two indexed Elixir sources for the demo project.
  Every fixture carries a distinctive `seedling-*` keyword so demos and tests
  can assert on keyword search, `find/2`, and `grep/2` hits.

  ```elixir
  {:ok, report} = AgentDb.Seed.seed()
  {:ok, report} = AgentDb.Seed.seed(prefix: "viking://resources/custom", force: true)
  ```

  ## Safety

  The seed refuses a store that already holds data (`{:error, :store_not_empty}`)
  unless `force: true` (merge: missing seed URIs are created, present ones
  revised in place, nothing deleted) or `clean: true` (only the seed scope is
  removed first: the prefix subtree, the `demo-*` memories, the demo skill,
  and the demo code prefix; data outside that scope survives). A refusal
  writes nothing. An invalid prefix fails with `:invalid_uri` on the first
  write, also having written nothing.

  Pass `env: :prod` (the Mix task passes `Mix.env()`) to engage the
  production guard: seeding in production without `allow_prod: true` is
  refused as `{:error, :production_guarded}` with nothing written. The
  library never reads `Mix.env/0` itself, so releases without Mix behave the
  same through the explicit option.

  ## Scope

  The `:prefix` override (default `"viking://resources/demo"`) scopes the
  documents and the committed session. Memories, the demo skill (user
  `"demo"`), and the demo code entries live at fixed global URIs by design,
  so a custom prefix still revises the same memories, skill, and code.

  ## Report

  Success answers `{:ok, report}` with the prefix used and per-kind counts:

      %{prefix: ..., documents: 5, memories: 5, sessions: 1, messages: 3,
        session: "<prefix>/sessions/intro.md", skills: 1, skill_files: 2,
        indexed: 2}

  Re-running converges: the same URIs are revised (memories supersede, the
  skill is replaced whole, the session document is rewritten), so the tree
  holds one active value per URI. Each run opens a new session row to commit
  from; only the committed document is part of the dataset.

  Rollback is `AgentDb.rm(prefix)` plus forgetting the `demo-*` memory URIs;
  re-seeding afterwards converges. Reads need no model: keyword search,
  find, and grep reach seeded content immediately, while embeddings and
  summaries regenerate through the existing job queue.
  """

  @default_prefix "viking://resources/demo"
  @demo_project "demo"
  @code_prefix "viking://resources/demo/code"
  @seed_user "demo"
  @skill_name "demo-skill"
  @skill_uri "viking://user/demo/skills/demo-skill"

  @type report :: %{
          prefix: String.t(),
          documents: non_neg_integer(),
          memories: non_neg_integer(),
          sessions: non_neg_integer(),
          messages: non_neg_integer(),
          session: String.t(),
          skills: non_neg_integer(),
          skill_files: non_neg_integer(),
          indexed: non_neg_integer()
        }

  @doc """
  Builds the demo dataset described in the module documentation.

  Options:

    * `:prefix` - demo prefix for documents and the committed session
      (default `"viking://resources/demo"`).
    * `:force` - merge into a non-empty store instead of refusing it.
    * `:clean` - remove only the seed scope, then seed.
    * `:env` - caller environment, e.g. `Mix.env()`; `:prod` engages the
      production guard.
    * `:allow_prod` - allow seeding when `env: :prod` (default `false`).
  """
  @spec seed(keyword()) :: {:ok, report()} | {:error, term()}
  def seed(opts \\ []) when is_list(opts) do
    prefix = normalize_prefix(Keyword.get(opts, :prefix, @default_prefix))

    with :ok <- check_prefix(prefix),
         :ok <- check_prod(opts) do
      cond do
        Keyword.get(opts, :clean, false) ->
          with :ok <- reset_scope(prefix), do: do_seed(prefix)

        Keyword.get(opts, :force, false) ->
          do_seed(prefix)

        true ->
          with :ok <- check_empty(), do: do_seed(prefix)
      end
    end
  end

  @doc "The default demo prefix documents and the committed session live under."
  @spec default_prefix() :: String.t()
  def default_prefix, do: @default_prefix

  # -- guards --

  defp normalize_prefix(prefix) when is_binary(prefix), do: String.trim_trailing(prefix, "/")
  defp normalize_prefix(_prefix), do: ""

  defp check_prefix(""), do: {:error, :invalid_uri}
  defp check_prefix(prefix) when is_binary(prefix), do: :ok

  defp check_prod(opts) do
    if Keyword.get(opts, :env) == :prod and not Keyword.get(opts, :allow_prod, false) do
      {:error, :production_guarded}
    else
      :ok
    end
  end

  # A non-empty store is any document subtree or any active memory. Sessions
  # that were never committed are invisible here by design: they have no URI
  # to collide with the dataset. Anything unexpected (a transient store
  # error) refuses rather than seeding over an unknown state.
  defp check_empty do
    with {:ok, resources_empty} <- subtree_empty?("viking://resources"),
         {:ok, user_empty} <- subtree_empty?("viking://user"),
         {:ok, memories} <- AgentDb.recall() do
      if resources_empty and user_empty and memories == [] do
        :ok
      else
        {:error, :store_not_empty}
      end
    end
  end

  defp subtree_empty?(uri) do
    case AgentDb.tree(uri, 1) do
      {:error, :not_found} -> {:ok, true}
      {:ok, %{children: []}} -> {:ok, true}
      {:ok, %{children: [_ | _]}} -> {:ok, false}
      {:ok, _} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  defp reset_scope(prefix) do
    with :ok <- rm_ignoring_missing(prefix),
         :ok <- rm_ignoring_missing(@code_prefix),
         :ok <- rm_ignoring_missing(@skill_uri),
         :ok <- forget_demo_memories() do
      :ok
    end
  end

  defp rm_ignoring_missing(uri) do
    case AgentDb.rm(uri) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = err -> err
    end
  end

  defp forget_demo_memories do
    Enum.reduce_while(memory_uris(), :ok, fn uri, :ok ->
      case AgentDb.forget(uri) do
        :ok -> {:cont, :ok}
        {:error, :no_memory} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # -- dataset --

  defp do_seed(prefix) do
    docs = documents(prefix)

    with :ok <- write_docs(docs),
         {:ok, _} <- remember_memories(),
         {:ok, session_uri} <- commit_session(prefix),
         {:ok, skill_files} <- import_skill(),
         {:ok, indexed} <- index_code() do
      {:ok,
       %{
         prefix: prefix,
         documents: length(docs),
         memories: length(memory_uris()),
         sessions: 1,
         messages: length(session_messages()),
         session: session_uri,
         skills: 1,
         skill_files: skill_files,
         indexed: length(indexed)
       }}
    end
  end

  defp write_docs(docs) do
    Enum.reduce_while(docs, :ok, fn {uri, content}, :ok ->
      case AgentDb.write(uri, content) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp remember_memories do
    Enum.reduce_while(memories(), {:ok, []}, fn {uri, value}, {:ok, acc} ->
      case AgentDb.remember(uri, value, confidence: 0.8) do
        {:ok, stored} -> {:cont, {:ok, [stored | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp commit_session(prefix) do
    dest = prefix <> "/sessions/intro.md"

    with {:ok, session_id} <- AgentDb.create_session(),
         :ok <- append_messages(session_id),
         {:ok, result} <- AgentDb.commit_session(session_id, dest) do
      case result do
        :unchanged -> {:ok, dest}
        uri when is_binary(uri) -> {:ok, uri}
      end
    end
  end

  defp append_messages(session_id) do
    Enum.reduce_while(session_messages(), :ok, fn {role, content}, :ok ->
      case AgentDb.append_message(session_id, role, content) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp import_skill do
    source =
      {:uploads,
       [
         %{path: "#{@skill_name}/SKILL.md", content: skill_manifest()},
         %{path: "#{@skill_name}/references/guide.md", content: skill_guide()}
       ]}

    case AgentDb.import_skills(@seed_user, source) do
      {:ok, %{skills: [%{status: status, files: files}]}} when status in [:imported, :replaced] ->
        {:ok, files}

      {:ok, %{skills: [%{status: :failed, reason: reason}]}} ->
        {:error, reason}

      {:ok, _} ->
        {:error, :skill_import_failed}

      {:error, _} = err ->
        err
    end
  end

  defp index_code do
    Enum.reduce_while(code_sources(), {:ok, []}, fn {rel, content}, {:ok, acc} ->
      case AgentDb.CodeIndex.index_source(@demo_project, rel, content) do
        {:ok, %{uri: uri}} -> {:cont, {:ok, [uri | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # -- fixtures --

  defp documents(prefix) do
    [
      {"readme.md",
       "# Demo project\n\nSeed baseline for dev and test (seedling-demo).\n\n- auth notes: `auth-notes.md`\n- runbook: `runbook.md`\n"},
      {"auth-notes.md",
       "# Auth notes\n\nDemo login uses the `seedling-auth` token `demo-token-123`.\n\nNever use this outside dev.\n"},
      {"runbook.md",
       "# Runbook\n\n`demo-runbook` restart: run `mix phx.server`, then `mix agent_db.doctor`.\n"},
      {"glossary.md",
       "# Glossary\n\n- `seedling-glossary`: a demo term the seed tests assert on.\n"},
      {"changelog.md", "# Changelog\n\n- 0.1.0 `seedling-changelog`: seeded baseline.\n"}
    ]
    |> Enum.map(fn {name, content} -> {prefix <> "/" <> name, content} end)
  end

  defp memory_uris do
    [
      "viking://user/memories/profile/demo-name",
      "viking://user/memories/preferences/demo-language",
      "viking://user/memories/entities/demo-project",
      "viking://user/memories/events/demo-release",
      "viking://user/memories/experiences/demo-onboarding"
    ]
  end

  defp memories do
    [
      {"viking://user/memories/profile/demo-name",
       "Demo user Ada works in Europe/Berlin (seedling-profile memory)."},
      {"viking://user/memories/preferences/demo-language",
       "Demo user prefers Elixir over Go (seedling-memory preferences)."},
      {"viking://user/memories/entities/demo-project",
       "Demo project agent_db tracks offline context (seedling-memory entities)."},
      {"viking://user/memories/events/demo-release",
       "Demo project released 0.1.0 in October 2026 (seedling-memory events)."},
      {"viking://user/memories/experiences/demo-onboarding",
       "Seeding then searching found the demo docs on the first try (seedling-memory experiences)."}
    ]
  end

  defp session_messages do
    [
      user: "Remember the demo baseline (seedling-session).",
      assistant: "Seeded five docs, five memories, one skill, and two code files.",
      user: "Commit this so search and recall can find it."
    ]
  end

  defp skill_manifest do
    "---\nname: demo-skill\ndescription: Seeded demo skill for dev and test.\n---\n\n# Demo skill\n\nSeeded by `mix agent_db.seed` (seedling-skill).\n"
  end

  defp skill_guide do
    "# Guide\n\nUse `seedling-skill` content to verify skill read-back.\n"
  end

  defp code_sources do
    [
      {"demo_seed.ex",
       "defmodule DemoSeed do\n  @moduledoc \"Seeded demo module (seedling-code).\"\n\n  def hello, do: :seedling_code\nend\n"},
      {"demo_seed/worker.ex",
       "defmodule DemoSeed.Worker do\n  @moduledoc \"Seeded demo worker (seedling-code).\"\n\n  def run(arg), do: {:ok, arg}\nend\n"}
    ]
  end
end
