defmodule AgentDbWeb.Controllers.SessionController do
  @moduledoc """
  Sessions over HTTP.
  """
  use AgentDbWeb, :controller

  alias AgentDbWeb.Context

  def create(conn, _params) do
    case AgentDb.create_session() do
      {:ok, session_id} -> json(conn, %{session_id: session_id})
      {:error, _reason} -> conn |> put_status(500) |> json(%{error: "internal_server_error"})
    end
  end

  # The nested routes name the session `:session_id`, matching how the resource
  # is addressed there; the same session is the `:id` of the resource itself.
  def show(conn, %{"id" => id}) do
    case Context.get_session(id) do
      {:ok, messages} -> json(conn, %{session_id: id, messages: messages})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, _reason} -> conn |> put_status(500) |> json(%{error: "internal_server_error"})
    end
  end

  def append_message(conn, %{
        "session_id" => id,
        "message" => %{"role" => role, "content" => content}
      }) do
    case AgentDb.append_message(id, role(role), content) do
      :ok -> json(conn, %{status: "appended"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: describe(reason)})
    end
  end

  def commit(conn, %{"session_id" => id, "commit" => %{"destination_uri" => destination}}) do
    case AgentDb.commit_session(id, destination) do
      {:ok, result} -> json(conn, %{status: "committed", result: result})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: describe(reason)})
    end
  end

  # A role arrives as the word the wire carries. One outside the set a session
  # holds is not turned into a term: an unrecognised role is a bad request, not
  # a reason to grow the vocabulary of stored rows.
  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("system"), do: :system
  defp role(_other), do: :unknown

  defp describe(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp describe({tag, _detail}) when is_atom(tag), do: tag
  defp describe(reason), do: inspect(reason)
end
