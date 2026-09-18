defmodule AgentDbWeb.Controllers.SessionController do
  use AgentDbWeb, :controller
  alias AgentDbWeb.Context

  def create(conn, _params) do
    with {:ok, session_id} <- AgentDb.create_session() do
      json(conn, %{session_id: session_id})
    else
      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: reason})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, messages} <- Context.get_session(id) do
      json(conn, %{session_id: id, messages: messages})
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})
      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: reason})
    end
  end

  def append_message(conn, %{"id" => id, "message" => params}) do
    role = params["role"] || "user"
    content = params["content"]

    with :ok <- AgentDb.append_message(id, String.to_existing_atom(role), content) do
      json(conn, %{status: "appended"})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason})
    end
  end

  def commit(conn, %{"id" => id, "commit" => params}) do
    destination_uri = params["destination_uri"]
    opts = params["opts"] || []

    with {:ok, result} <- AgentDb.commit_session(id, destination_uri, opts) do
      json(conn, %{status: "committed", result: result})
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason})
    end
  end
end