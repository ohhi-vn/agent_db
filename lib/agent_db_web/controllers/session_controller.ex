defmodule AgentDbWeb.Controllers.SessionController do
  @moduledoc """
  Sessions over HTTP.
  """
  use AgentDbWeb, :controller

  alias AgentDb.Observability
  alias AgentDbWeb.Context

  def create(conn, _params) do
    case AgentDb.create_session() do
      {:ok, session_id} -> json(conn, %{session_id: session_id})
      {:error, reason} -> transport_error(conn, reason)
    end
  end

  # The nested routes name the session `:session_id`, matching how the resource
  # is addressed there; the same session is the `:id` of the resource itself.
  def show(conn, %{"id" => id}) do
    case Context.get_session(id) do
      {:ok, messages} -> json(conn, %{session_id: id, messages: messages})
      {:error, reason} -> transport_error(conn, reason)
    end
  end

  def append_message(conn, %{
        "session_id" => id,
        "message" => %{"role" => role, "content" => content}
      }) do
    case AgentDb.append_message(id, role(role), content) do
      :ok -> json(conn, %{status: "appended"})
      {:error, reason} -> transport_error(conn, reason)
    end
  end

  def commit(conn, %{"session_id" => id, "commit" => %{"destination_uri" => destination}}) do
    case AgentDb.commit_session(id, destination) do
      {:ok, result} -> json(conn, %{status: "committed", result: result})
      {:error, reason} -> transport_error(conn, reason)
    end
  end

  # A role arrives as the word the wire carries. One outside the set a session
  # holds is not turned into a term: an unrecognised role is a bad request, not
  # a reason to grow the vocabulary of stored rows.
  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("system"), do: :system
  defp role(_other), do: :unknown

  # One rendering for every store error: status from the shared taxonomy, body
  # always JSON-safe with a machine-readable code, details never echoed.
  defp transport_error(conn, reason) do
    conn
    |> put_status(Observability.http_status(reason))
    |> json(%{error: Observability.error_message(reason), code: Observability.error_code(reason)})
  end
end
