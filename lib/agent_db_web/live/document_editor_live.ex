defmodule AgentDbWeb.DocumentEditorLive do
  use AgentDbWeb, :live_view
  alias AgentDbWeb.Context

  def mount(%{"id" => uri}, _session, socket) do
    decoded_uri = URI.decode(uri)
    {:ok, content} = Context.get_document(decoded_uri)
    
    draft = get_draft(decoded_uri)
    content_to_show = if draft != "", do: draft, else: content
    
    {:ok, assign(socket, 
      uri: decoded_uri,
      content: content,
      draft: content_to_show,
      abstract: load_abstract(decoded_uri),
      overview: load_overview(decoded_uri),
      saved: true
    )}
  end

  def handle_event("save_draft", %{"content" => content}, socket) do
    save_draft(socket.assigns.uri, content)
    {:noreply, assign(socket, draft: content, saved: false)}
  end

  def handle_event("publish", %{"content" => content}, socket) do
    case Context.update_document(socket.assigns.uri, content, []) do
      {:ok, _} ->
        clear_draft(socket.assigns.uri)
        {:noreply, 
          socket
          |> assign(draft: content, saved: true)
          |> put_flash(:info, "Document published successfully")
          |> push_patch(to: "/admin")}
      {:error, reason} ->
        {:noreply, 
          put_flash(socket, :error, "Failed to publish: #{reason}")
          |> assign(draft: content)}
    end
  end

  defp get_draft(uri) do
    # In a real implementation, this would read from a draft store
    # For now, return empty string
    ""
  end

  defp save_draft(_uri, _content) do
    # In a real implementation, this would save to localStorage via JS hook
    # or a draft table in the database
    :ok
  end

  defp clear_draft(_uri) do
    :ok
  end

  defp load_abstract(uri) do
    with {:ok, abstract} <- AgentDb.abstract(uri) do
      abstract
    else
      {:error, _} -> "No abstract available"
    end
  end

  defp load_overview(uri) do
    with {:ok, overview} <- AgentDb.overview(uri) do
      overview
    else
      {:error, _} -> "No overview available"
    end
  end
end