defmodule AgentDb.URI do
  @moduledoc false

  # viking:// URI parsing and validation (D5).
  # - URIs parse to segment lists.
  # - Rejected: missing viking:// scheme, empty segments, "." / "..",
  #   backslashes, control characters.
  # - %-encoding is preserved verbatim (no decode) so cache keys and SQLite
  #   keys are byte-identical.
  # - URIs are never converted to atoms.

  @type t :: String.t()
  @type segments :: [String.t()]

  @scheme "viking://"

  @spec parse(t()) :: {:ok, segments()} | {:error, :invalid_uri}
  def parse(uri)

  def parse(@scheme <> rest) do
    segments = String.split(rest, "/")

    cond do
      # exactly the scheme, no trailing slash content
      rest == "" ->
        {:ok, []}

      # double slashes / leading or trailing empties (besides root itself)
      Enum.any?(segments, &(&1 == "")) ->
        {:error, :invalid_uri}

      valid_segments?(segments) ->
        {:ok, segments}

      true ->
        {:error, :invalid_uri}
    end
  end

  def parse(_), do: {:error, :invalid_uri}

  @spec build(segments()) :: t()
  def build([]), do: @scheme
  def build(segments), do: @scheme <> Enum.join(segments, "/")

  @doc "Parent URI of a parsed URI; root has no parent."
  @spec parent(segments()) :: {:ok, segments()} | :root
  def parent([]), do: :root
  def parent(segments), do: {:ok, Enum.drop(segments, -1)}

  @doc "Join a child segment onto parsed segments."
  @spec join(segments(), String.t()) :: {:ok, segments()} | {:error, :invalid_uri}
  def join(segments, segment) do
    if valid_segment?(segment) do
      {:ok, segments ++ [segment]}
    else
      {:error, :invalid_uri}
    end
  end

  @doc "URI prefix for subtree scoping: viking://resources/p -> viking://resources/p/ (byte prefix)."
  @spec scope_prefix(t(), segments()) :: String.t()
  def scope_prefix(_uri, segments) do
    case segments do
      [] -> @scheme
      _ -> @scheme <> Enum.join(segments, "/") <> "/"
    end
  end

  defp valid_segments?(segments), do: Enum.all?(segments, &valid_segment?/1)

  defp valid_segment?(segment) when is_binary(segment) do
    segment != "" and
      segment not in [".", ".."] and
      not String.contains?(segment, "\\") and
      not String.contains?(segment, "\0") and
      not has_control_char?(segment)
  end

  defp valid_segment?(_), do: false

  defp has_control_char?(segment) do
    String.to_charlist(segment)
    |> Enum.any?(fn c -> c < 0x20 or c == 0x7F end)
  end
end
