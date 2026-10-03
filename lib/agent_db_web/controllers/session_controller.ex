defmodule AgentDbWeb.Controllers.SessionController do
  @moduledoc """
  Sessions over HTTP.
  """
  use AgentDbWeb, :controller

  alias AgentDbWeb.Context

  def create(conn, _params) do
    case AgentDb.create_session() do
      {:ok, session_id} -> json(conn, %{session_id: session_id})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  # The nested routes name the session `:session_id`, matching how the resource
  # is addressed there; the same session is the `:id` of the resource itself.
  def show(conn, %{"id" => id}) do
    case Context.get_session(id) do
      {:ok, messages} -> json(conn, %{session_id: id, messages: messages})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def append_message(conn, %{
        "session_id" => id,
        "message" => %{"role" => role, "content" => content}
      }) do
    case AgentDb.append_message(id, Context.role(role), content) do
      :ok -> json(conn, %{status: "appended"})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end

  def commit(conn, %{"session_id" => id, "commit" => %{"destination_uri" => destination}}) do
    case AgentDb.commit_session(id, destination) do
      {:ok, result} -> json(conn, %{status: "committed", result: result})
      {:error, reason} -> Context.transport_error(conn, reason)
    end
  end
end
