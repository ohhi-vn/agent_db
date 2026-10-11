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

  alias AgentDb.URI, as: VikingURI
  alias AgentDbWeb.AdminComponents
  alias AgentDbWeb.Context

  # Same fallback as the admin pages: converge after a missed event or
  # reconnect. The guard in refresh_stored/2 keeps it from touching a draft.
  @refresh_ms 30_000

  @impl Phoenix.LiveView
  def mount(%{"id" => uri}, _session, socket) do
    if connected?(socket) do
      # The root is an ancestor of every change; relevance to the open
      # document is filtered in handle_info. Process-scoped like the admin
      # pages: it ends with this LiveView.
      _ = AgentDb.subscribe("viking://")
      :timer.send_interval(@refresh_ms, self(), :refresh)
    end

    case Context.get_document(uri) do
      {:ok, content} ->
        {:ok,
         socket
         |> assign(
           active: :documents,
           uri: uri,
           content: content,
           draft: content,
           saved: true,
           notice: nil
         )
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
  def handle_info({:context_changed, changed_uri, _kind, _version}, socket) do
    {:noreply, maybe_refresh(socket, changed_uri)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, refresh_stored(socket, nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="p-8 space-y-6">
      <h1 class="font-mono text-sm text-gray-500"><%= @uri %></h1>

      <p :if={@notice} class="rounded bg-blue-50 px-3 py-2 text-sm text-blue-900"><%= @notice %></p>

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

      <AdminComponents.llm_layers layers={@layers} />
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
         |> assign(content: draft, draft: draft, saved: true, notice: nil)
         |> put_flash(:info, "Published")
         |> assign_layers()}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not publish: #{Context.error_message(reason)}")}
    end
  end

  # A refresh re-reads the stored document. Content and draft are only
  # rewritten when nothing unsaved is on screen; a dirty draft is never
  # touched, and a document that is gone keeps the draft with a notice.
  defp maybe_refresh(socket, changed_uri) do
    if relevant?(socket.assigns.uri, changed_uri) do
      refresh_stored(socket, changed_uri)
    else
      socket
    end
  end

  # The event carries the change root: the open document itself, or an
  # ancestor of it (a replaced skill subtree, a removed parent).
  defp relevant?(uri, changed_uri) when is_binary(uri) and is_binary(changed_uri) do
    with {:ok, open} <- VikingURI.parse(uri),
         {:ok, changed} <- VikingURI.parse(changed_uri) do
      Enum.take(open, length(changed)) == changed
    else
      _ -> false
    end
  end

  defp relevant?(_uri, _changed), do: false

  defp refresh_stored(socket, changed_uri) do
    uri = socket.assigns.uri

    case Context.get_document(uri) do
      {:ok, new_content} ->
        if socket.assigns.saved do
          socket
          |> assign(content: new_content, draft: new_content, notice: nil)
          |> assign_layers()
        else
          socket = assign_layers(socket)

          if new_content != socket.assigns.draft do
            assign(socket,
              notice:
                "Changed underneath#{at(changed_uri)}; showing your unsaved draft. Publish overwrites the stored version."
            )
          else
            assign(socket, notice: nil)
          end
        end

      {:error, _reason} ->
        socket
        |> assign_layers()
        |> assign(
          notice: "No longer stored at #{uri}#{at(changed_uri)}. Your draft is preserved."
        )
    end
  end

  defp at(nil), do: ""
  defp at(uri), do: " by #{uri}"

  # The layers are read after publishing rather than carried in the socket: they
  # are generated in the background, so a fresh read is the only one that can
  # show what has arrived since. Source and size travel with the text, so the
  # view shows what the LLM sees rather than just the words.
  defp assign_layers(socket) do
    assign(socket, layers: Context.get_layers(socket.assigns.uri))
  end
end
