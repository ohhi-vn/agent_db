defmodule AgentDbWeb.DocumentEditorLive do
  @moduledoc """
  Editing one document.

  A draft is held in the socket and shown alongside the stored content, so an
  edit is visible before it is published and a reload before publishing loses
  nothing the operator can see they have written.
  """
  use Phoenix.LiveView, layout: {AgentDbWeb.Layouts, :admin}

  import Phoenix.LiveView
  import Phoenix.Component

  alias AgentDbWeb.Context

  @impl Phoenix.LiveView
  def mount(%{"id" => uri}, _session, socket) do
    case Context.get_document(uri) do
      {:ok, content} ->
        {:ok,
         socket
         |> assign(active: :documents, uri: uri, content: content, draft: content, saved: true)
         |> assign_layers()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "No document at #{uri}")
         |> push_patch(to: "/admin")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("edit", %{"draft" => draft}, socket) do
    {:noreply, assign(socket, draft: draft, saved: false)}
  end

  def handle_event("publish", _params, socket) do
    publish(socket)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-6">
      <h1 class="font-mono text-sm text-gray-500"><%= @uri %></h1>

      <form phx-submit="publish" class="space-y-4">
        <label for="document-draft" class="sr-only">Document content</label>
        <textarea
          id="document-draft"
          name="draft"
          phx-change="edit"
          rows="20"
          class="w-full rounded-lg border border-gray-300 p-3 font-mono text-sm"
        ><%= @draft %></textarea>

        <div class="flex items-center gap-4">
          <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-sm text-white">Publish</button>
          <span :if={not @saved} class="text-sm text-amber-700">Unsaved changes</span>
          <span :if={@saved} class="text-sm text-gray-500">Saved</span>
        </div>
      </form>

      <dl class="grid gap-4 text-sm">
        <div>
          <dt class="text-gray-500">Abstract (L0)</dt>
          <dd class="text-gray-900"><%= @abstract %></dd>
        </div>
        <div>
          <dt class="text-gray-500">Overview (L1)</dt>
          <dd class="text-gray-900"><%= @overview %></dd>
        </div>
      </dl>
    </div>
    """
  end

  defp publish(socket) do
    uri = socket.assigns.uri
    draft = socket.assigns.draft

    case Context.put_document(uri, draft) do
      :ok ->
        {:noreply,
         socket
         |> assign(content: draft, draft: draft, saved: true)
         |> put_flash(:info, "Published")
         |> assign_layers()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not publish: #{Context.error_message(reason)}")}
    end
  end

  # The layers are read after publishing rather than carried in the socket: they
  # are generated in the background, so a fresh read is the only one that can
  # show what has arrived since.
  defp assign_layers(socket) do
    assign(socket,
      abstract: layer(socket.assigns.uri, &AgentDb.abstract/1),
      overview: layer(socket.assigns.uri, &AgentDb.overview/1)
    )
  end

  defp layer(uri, read) do
    case read.(uri) do
      {:ok, text} -> text
      {:error, _reason} -> "Not available"
    end
  end
end
