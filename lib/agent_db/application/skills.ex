defmodule AgentDb.Application.Skills do
  @moduledoc false

  # Importing Agent Skills into a user's skills subtree.
  #
  # Both ways in -- the console and the Mix task -- reach this one workflow, so
  # what a bundle has to look like, what is refused, and where a skill lands are
  # decided once. A source is read and validated whole before anything is
  # written: a bundle that is refused leaves the store exactly as it was, rather
  # than holding the half of it that was read before the refusal.
  #
  # After that, each skill is replaced on its own, so a store that cannot take
  # one of them does not cost the operator the others. The outcome of every skill
  # is reported, whether it was written, whether it replaced what was there, or
  # why it could not.

  alias AgentDb.Cache
  alias AgentDb.Runtime
  alias AgentDb.Skills.Source
  alias AgentDb.URI, as: VikingURI

  @type source :: Source.source()
  @type result :: %{
          name: String.t(),
          status: :imported | :replaced | :failed,
          files: non_neg_integer(),
          reason: term() | nil
        }

  @doc """
  Imports every skill a source holds below `viking://user/{user_id}/skills`.

  A skill already stored under that name is replaced whole: the files the new
  source does not have are removed with it, and a replacement that fails leaves
  the stored skill as it was.

  Answers the outcome of every skill, or one error for the source as a whole --
  which is only ever a refusal, since nothing is written until the source has
  been accepted. See `AgentDb.Skills.Source.message/1` for the reason in words.
  """
  @spec import(String.t(), source()) :: {:ok, %{skills: [result()]}} | {:error, term()}
  def import(user_id, source) do
    with {:ok, segments} <- user_segments(user_id),
         {:ok, skills} <- Source.load(source) do
      {:ok, %{skills: Enum.map(skills, &replace(segments, &1))}}
    end
  end

  @doc "The bounds one import accepts, shared by every way in."
  @spec limits() :: map()
  defdelegate limits(), to: Source

  # A user is part of a URI like any other, so an ID that could not be one
  # segment of it is refused before a source is even read. The rules are the URI
  # module's: the destination is built and read back, and an ID that turned out
  # to be more than one segment is not the user it was asked for.
  defp user_segments(user_id) when is_binary(user_id) do
    case VikingURI.parse(VikingURI.build(["user", user_id, "skills"])) do
      {:ok, ["user", ^user_id, "skills"] = segments} -> {:ok, segments}
      _other -> {:error, {:invalid_user_id, user_id}}
    end
  end

  defp user_segments(user_id), do: {:error, {:invalid_user_id, user_id}}

  defp replace(segments, %{name: name, files: files}) do
    uri = VikingURI.build(segments ++ [name])

    case Runtime.storage().replace_skill(uri, files) do
      {:ok, %{replaced: replaced, files: stored}} ->
        # Committed storage and cached reads have to agree, and the cache answers
        # what it was given last: a replaced subtree is dropped whole, so a read
        # of a file the new source removed cannot be served from before it.
        Cache.invalidate_removal(uri)

        %{
          name: name,
          status: if(replaced, do: :replaced, else: :imported),
          files: stored,
          reason: nil
        }

      {:error, reason} ->
        %{name: name, status: :failed, files: 0, reason: reason}
    end
  end
end
