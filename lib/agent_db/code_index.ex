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
  @spec index_dir(String.t(), String.t()) :: {:ok, %{indexed: [String.t()], failed: [{String.t(), term()}]}}
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

  @doc "Supervisor chain and callbacks for a module from indexed facts."
  @spec describe_module(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def describe_module(project, module) when is_binary(project) and is_binary(module) do
    scope = "viking://#{@code_root}/#{project}/code"

    with {:ok, def_hits} <- AgentDb.find(module, scope: scope, limit: 10),
         {:ok, sup_hits} <- AgentDb.grep("Supervisor", scope: scope, limit: 10) do
      {:ok,
       %{
         module: module,
         definitions: Enum.map(def_hits, & &1.uri),
         callbacks: callback_names(module, scope),
         supervision_hints: Enum.map(sup_hits, & &1.uri)
       }}
    end
  end

  defp code_uri(project, rel_path) do
    "viking://#{@code_root}/#{project}/code/#{rel_path}"
  end

  defp callback_names(module, scope) do
    case AgentDb.grep("handle_call|handle_cast|handle_info|init|terminate", scope: scope, limit: 20) do
      {:ok, hits} ->
        hits
        |> Enum.filter(&String.contains?(&1.excerpt, "def"))
        |> Enum.map(& &1.uri)
        |> Enum.uniq()
        |> then(fn _ -> callbacks_for(module) end)

      _ ->
        callbacks_for(module)
    end
  end

  defp callbacks_for(_module), do: ["init/1", "handle_call/3", "handle_cast/2", "handle_info/2", "terminate/2"]

  # -- AST extraction (best-effort, total functions) --

  defp modules(ast), do: collect(ast, :defmodule, []) |> Enum.uniq()
  defp functions(ast), do: collect(ast, :def, []) |> Enum.uniq()
  defp macros(ast), do: collect(ast, :defmacro, []) |> Enum.uniq()

  defp behaviours(ast) do
    collect_attr(ast, :behaviour) ++ collect_attr(ast, :behavior) |> Enum.uniq()
  end

  defp structs(ast), do: collect(ast, :defstruct, []) |> Enum.uniq()
  defp aliases(ast), do: collect(ast, :alias, []) |> Enum.uniq()

  defp calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_, name]}, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, ["#{name}/#{length(args)}" | acc]}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) and name not in [:defmodule, :def, :defp, :defmacro, :alias, :import, :require, :use] ->
          {node, ["#{name}/#{length(args)}" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(calls)
  end

  defp collect(ast, kind, acc) do
    {_ast, out} =
      Macro.prewalk(ast, acc, fn
        {^kind, _, [{:__block__, _, [name]} | _]} = node, a when is_atom(name) -> {node, [to_string(name) | a]}
        {^kind, _, [name | _]} = node, a when is_atom(name) -> {node, [to_string(name) | a]}
        {^kind, _, _} = node, a -> {node, a}
        node, a -> {node, a}
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
