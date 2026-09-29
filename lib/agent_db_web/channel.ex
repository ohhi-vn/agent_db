defmodule AgentDbWeb.Channel do
  @moduledoc """
  The WebSocket surface.

  Events are versioned (`v1.write`, `v1.search`) so a change that would break a
  client can arrive as `v2` with this one still answering. Every call goes
  through the `AgentDb` facade, and every one answers -- a call that cannot be
  served comes back as an error the client can act on, and the connection stays
  usable afterwards.

  A call deferred only because a model is still loading is reported distinctly
  from a call that failed, so a client retries the first rather than concluding
  the capability is gone.
  """
  use Phoenix.Channel

  alias AgentDb

  @impl true
  def join("api:lobby", _params, socket) do
    # Authentication happens at connect, in AgentDbWeb.WebSocket: a socket
    # already open is an authenticated one.
    {:ok, socket}
  end

  # -- documents --

  @impl true
  def handle_in("v1.write", %{"uri" => uri, "content" => content} = params, socket) do
    answer(socket, AgentDb.write(uri, content, write_opts(params["opts"])))
  end

  def handle_in("v1.read", %{"uri" => uri}, socket) do
    case AgentDb.read(uri) do
      {:ok, content} -> answer(socket, {:ok, %{content: content}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in("v1.abstract", %{"uri" => uri}, socket) do
    case AgentDb.abstract(uri) do
      {:ok, abstract} -> answer(socket, {:ok, %{abstract: abstract}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in("v1.overview", %{"uri" => uri}, socket) do
    case AgentDb.overview(uri) do
      {:ok, overview} -> answer(socket, {:ok, %{overview: overview}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in("v1.list", %{"uri" => uri}, socket) do
    case AgentDb.list(uri) do
      {:ok, names} -> answer(socket, {:ok, %{names: names}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in("v1.tree", %{"uri" => uri} = params, socket) do
    case AgentDb.tree(uri, Map.get(params, "depth", 2)) do
      {:ok, tree} -> answer(socket, {:ok, %{tree: tree}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in("v1.rm", %{"uri" => uri}, socket) do
    answer(socket, AgentDb.rm(uri))
  end

  # -- search --

  def handle_in("v1.search", %{"term" => term} = params, socket) do
    case AgentDb.search(term, search_opts(params["opts"])) do
      {:ok, results} -> answer(socket, {:ok, %{results: results}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  # -- sessions --

  def handle_in("v1.create_session", _params, socket) do
    case AgentDb.create_session() do
      {:ok, session_id} -> answer(socket, {:ok, %{session_id: session_id}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in(
        "v1.append_message",
        %{"session_id" => id, "role" => role, "content" => content},
        socket
      ) do
    answer(socket, AgentDb.append_message(id, role(role), content))
  end

  def handle_in("v1.get_session", %{"session_id" => id}, socket) do
    case AgentDb.get_session(id) do
      {:ok, messages} -> answer(socket, {:ok, %{messages: messages}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in(
        "v1.commit_session",
        %{"session_id" => id, "destination_uri" => destination} = params,
        socket
      ) do
    case AgentDb.commit_session(id, destination, commit_opts(params["opts"])) do
      {:ok, result} -> answer(socket, {:ok, %{result: result}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  # -- memory --

  def handle_in("v1.remember", %{"uri" => uri, "value" => value} = params, socket) do
    answer(socket, AgentDb.remember(uri, value, memory_opts(params["opts"])))
  end

  def handle_in("v1.recall", params, socket) do
    case AgentDb.recall(recall_opts(params)) do
      {:ok, memories} -> answer(socket, {:ok, %{memories: memories}})
      {:error, _} = err -> answer(socket, err)
    end
  end

  def handle_in("v1.forget", %{"uri" => uri}, socket) do
    answer(socket, AgentDb.forget(uri))
  end

  # -- status --

  def handle_in("v1.model_status", _params, socket) do
    answer(socket, {:ok, AgentDb.model_status()})
  end

  def handle_in("v1.health", _params, socket) do
    answer(socket, {:ok, AgentDb.health_check()})
  end

  def handle_in(event, _params, socket) do
    answer(socket, {:error, {:unknown_event, event}})
  end

  # -- replies --

  # An error is rendered so a client can tell a deferral from a failure: the
  # first is a bare atom to retry, the second a tagged reason naming a cause.
  defp answer(socket, :ok), do: {:reply, {:ok, %{status: "ok"}}, socket}

  defp answer(socket, {:ok, payload}), do: {:reply, {:ok, payload}, socket}

  defp answer(socket, {:error, reason}), do: {:reply, {:error, %{reason: render(reason)}}, socket}

  defp render(:model_loading), do: :model_loading
  defp render(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp render({tag, detail}) when is_atom(tag), do: {tag, render(detail)}
  defp render(reason), do: inspect(reason)

  # -- options from the wire --

  # Options arrive as a string-keyed JSON map, which the store reads with
  # Keyword, so each is named here and passed through as the store's own
  # option. An unrecognised key is dropped rather than converted: a misspelt
  # option that became a term would be applied as though it had been asked for.
  defp write_opts(params) when is_map(params) do
    for {key, value} <- params, key in ["async", "sync_timeout_ms", "abstract", "overview"] do
      {String.to_existing_atom(key), value}
    end
  end

  defp write_opts(_params), do: []

  defp search_opts(params) when is_map(params) do
    carried =
      for {key, value} <- params, key in ["scope", "top_k", "hybrid_weights"] do
        {String.to_existing_atom(key), value}
      end

    [{:mode, search_mode(params["mode"])} | carried]
  end

  defp search_opts(_params), do: [mode: :keyword]

  # A mode arrives as the word the wire carries. One this transport does not
  # recognise is passed on as it arrived, so the store reports it as an invalid
  # mode rather than this module quietly choosing one on the client's behalf.
  defp search_mode(nil), do: :keyword
  defp search_mode("keyword"), do: :keyword
  defp search_mode("vector"), do: :vector
  defp search_mode("hybrid"), do: :hybrid
  defp search_mode(other), do: other

  defp commit_opts(params) when is_map(params) do
    # A formatter is a function and cannot cross a JSON boundary, so nothing is
    # carried; the named form keeps the shape explicit.
    _ = params
    []
  end

  defp commit_opts(_params), do: []

  defp memory_opts(params) when is_map(params) do
    for {key, value} <- params, key in ["confidence", "source"] do
      {String.to_existing_atom(key), value}
    end
  end

  defp memory_opts(_params), do: []

  defp recall_opts(params) when is_map(params) do
    for {key, value} <- params, key in ["uri", "term", "include_superseded"] do
      {String.to_existing_atom(key), value}
    end
  end

  defp recall_opts(_params), do: []

  # A role is a fixed vocabulary of stored values, so a word outside it is not
  # turned into a term.
  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("system"), do: :system
  defp role(_other), do: :unknown
end
