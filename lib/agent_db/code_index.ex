defmodule AgentDb.CodeIndex do
  @moduledoc false

  # Structural Elixir source indexing as ordinary context documents.
  #
  # Files are parsed with `Code.string_to_quoted/2`; facts are derived from
  # the AST without any model. Each file lands as an ordinary document under
  # `viking://resources/<project>/code/`, so `find/2`, `grep/2`, and `search/2`
  # reach it with no code-specific path. A file that fails to parse reports a
  # classified error for that file only.

  @code_root "resources"

  # The behaviour callbacks a supervised process may implement. A module is
  # reported as implementing one only when its own source defines it.
  @otp_callbacks [
    "init/1",
    "handle_call/3",
    "handle_cast/2",
    "handle_info/2",
    "terminate/2",
    "code_change/3"
  ]

  @doc "Indexes one source text as `viking://resources/<project>/code/<path>`."
  @spec index_source(String.t(), String.t(), String.t()) ::
          {:ok, %{uri: String.t(), facts: map()}} | {:error, term()}
  def index_source(project, rel_path, content)
      when is_binary(project) and is_binary(rel_path) and is_binary(content) do
    with {:ok, facts} <- facts(content),
         uri = code_uri(project, rel_path),
         :ok <- AgentDb.write(uri, content) do
      {:ok, %{uri: uri, facts: facts}}
    end
  end

  @doc "Indexes every `.ex`/`.exs` file beneath `dir` with per-file isolation."
  @spec index_dir(String.t(), String.t()) ::
          {:ok, %{indexed: [String.t()], failed: [{String.t(), term()}]}}
  def index_dir(project, dir) when is_binary(project) and is_binary(dir) do
    files = Path.wildcard(Path.join(dir, "**/*.{ex,exs}"))

    {indexed, failed} =
      Enum.reduce(files, {[], []}, fn path, {ok, err} ->
        rel = Path.relative_to(path, dir)

        case File.read(path) do
          {:ok, content} ->
            case index_source(project, rel, content) do
              {:ok, %{uri: uri}} -> {[uri | ok], err}
              {:error, reason} -> {ok, [{rel, reason} | err]}
            end

          {:error, reason} ->
            {ok, [{rel, reason} | err]}
        end
      end)

    {:ok, %{indexed: Enum.reverse(indexed), failed: Enum.reverse(failed)}}
  end

  @doc "Structural facts for source text without writing anything."
  @spec facts(String.t()) :: {:ok, map()} | {:error, term()}
  def facts(content) when is_binary(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {:ok,
         %{
           modules: modules(ast),
           functions: functions(ast),
           macros: macros(ast),
           behaviours: behaviours(ast),
           structs: structs(ast),
           aliases: aliases(ast),
           calls: calls(ast)
         }}

      {:error, _} = err ->
        {:error, {:parse_error, err}}
    end
  end

  @doc "Callers of `name/arity` within indexed code for `project`, ordered by URI."
  @spec callers(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def callers(project, target) when is_binary(project) and is_binary(target) do
    scope = "viking://#{@code_root}/#{project}/code"

    case AgentDb.grep(target, scope: scope, limit: 50) do
      {:ok, hits} -> {:ok, Enum.sort_by(hits, & &1.uri)}
      {:error, _} = err -> err
    end
  end

  @doc """
  How much source the store has indexed, as `%{projects: n, documents: n}`.

  Enumerates the projects under the code root and counts each one's subtree,
  so the cost follows the number of indexed projects rather than the number of
  indexed files. Safe to call from a console on a timer.
  """
  @spec coverage() :: %{projects: non_neg_integer(), documents: non_neg_integer()}
  def coverage do
    storage = AgentDb.Runtime.storage()
    root = "viking://#{@code_root}"

    case storage.list_children(root) do
      {:ok, names} ->
        roots =
          names
          |> Enum.map(&"#{root}/#{&1}/code")
          |> Enum.filter(&match?({:ok, n} when n > 0, storage.document_count(&1)))

        %{
          projects: length(roots),
          documents: Enum.reduce(roots, 0, &(&2 + storage.document_count(&1)))
        }

      {:error, _} ->
        %{projects: 0, documents: 0}
    end
  end

  @doc "Supervisor chain and callbacks for a module from indexed facts."
  @spec describe_module(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def describe_module(project, module) when is_binary(project) and is_binary(module) do
    scope = "viking://#{@code_root}/#{project}/code"

    with {:ok, def_uris} <- defining_files(scope, module),
         {:ok, sup_hits} <- AgentDb.grep("Supervisor", scope: scope, limit: 10) do
      {:ok,
       %{
         module: module,
         definitions: def_uris,
         callbacks: callback_names(def_uris),
         supervision_hints: Enum.map(sup_hits, & &1.uri)
       }}
    end
  end

  # The indexed files that declare `module`.
  #
  # Found by content rather than by `find/2`: `find` matches URI paths, and a
  # module name is not part of any path, so a module is only locatable in the
  # source that declares it. Searching on the declaration line is also what
  # makes the answer a fact about this module rather than about every module
  # in the project.
  defp defining_files(scope, module) do
    case AgentDb.grep("defmodule #{module}", scope: scope, limit: 10) do
      {:ok, hits} -> {:ok, hits |> Enum.map(& &1.uri) |> Enum.uniq() |> Enum.sort()}
      {:error, _} = err -> err
    end
  end

  defp code_uri(project, rel_path) do
    "viking://#{@code_root}/#{project}/code/#{rel_path}"
  end

  # Which of the GenServer callbacks the module actually defines, read from the
  # indexed source of the files that define it.
  #
  # A fixed list of callback names would report a `handle_cast/2` for a module
  # that has never handled a cast, which is the shape of a report an operator
  # cannot act on. When nothing can be read, the answer is no callbacks rather
  # than all of them: an unanswerable question is not a full one.
  defp callback_names(uris) do
    uris
    |> Enum.flat_map(&defined_callbacks/1)
    |> Enum.filter(&(&1 in @otp_callbacks))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp defined_callbacks(uri) do
    with {:ok, content} <- AgentDb.read(uri),
         {:ok, ast} <- Code.string_to_quoted(content) do
      definitions(ast)
    else
      _ -> []
    end
  end

  defp definitions(ast) do
    {_ast, out} =
      Macro.prewalk(ast, [], fn
        {kind, _, [{name, _, args} | _]} = node, acc
        when kind in [:def, :defmacro, :defp] and is_atom(name) and is_list(args) ->
          {node, ["#{name}/#{length(args)}" | acc]}

        node, acc ->
          {node, acc}
      end)

    out
  end

  # -- AST extraction (best-effort, total functions) --

  defp modules(ast), do: collect(ast, :defmodule, []) |> Enum.uniq()
  defp functions(ast), do: collect(ast, :def, []) |> Enum.uniq()
  defp macros(ast), do: collect(ast, :defmacro, []) |> Enum.uniq()

  defp behaviours(ast) do
    (collect_attr(ast, :behaviour) ++ collect_attr(ast, :behavior)) |> Enum.uniq()
  end

  defp structs(ast), do: collect(ast, :defstruct, []) |> Enum.uniq()
  defp aliases(ast), do: collect(ast, :alias, []) |> Enum.uniq()

  defp calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_, name]}, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, ["#{name}/#{length(args)}" | acc]}

        {name, _, args} = node, acc
        when is_atom(name) and is_list(args) and
               name not in [:defmodule, :def, :defp, :defmacro, :alias, :import, :require, :use] ->
          {node, ["#{name}/#{length(args)}" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp collect(ast, kind, acc) do
    {_ast, out} =
      Macro.prewalk(ast, acc, fn
        {^kind, _, [{:__block__, _, [name]} | _]} = node, a when is_atom(name) ->
          {node, [to_string(name) | a]}

        {^kind, _, [name | _]} = node, a when is_atom(name) ->
          {node, [to_string(name) | a]}

        {^kind, _, _} = node, a ->
          {node, a}

        node, a ->
          {node, a}
      end)

    out
  end

  defp collect_attr(ast, attr) do
    {_ast, out} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{^attr, _, [mod]}]} = node, a -> {node, [Macro.to_string(mod) | a]}
        node, a -> {node, a}
      end)

    out
  end
end
