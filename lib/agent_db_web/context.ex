defmodule AgentDbWeb.Context do
  @moduledoc """
  Shared context functions for controllers and LiveViews.
  """
  alias AgentDb
  alias AgentDb.ML.ModelManager
  alias AgentDb.Store.SQLite

  @doc """
  Lists documents with pagination and filtering.
  """
  def list_documents(opts \\ []) do
    # Normalize opts to keyword list
    opts = 
      cond do
        is_map(opts) -> Map.to_list(opts)
        is_list(opts) -> opts
        true -> []
      end
    
    page = get_opt(opts, "page", "1") |> String.to_integer()
    per_page = get_opt(opts, "per_page", "20") |> String.to_integer()
    prefix = get_opt(opts, "prefix", "")

    case AgentDb.list(prefix) do
      {:ok, names} ->
        total = length(names)
        start = (page - 1) * per_page
        paginated = Enum.slice(names, start, per_page) || []
        
        {:ok, %{
          data: paginated,
          meta: %{
            page: page,
            per_page: per_page,
            total: total,
            total_pages: div(total + per_page - 1, per_page)
          }
        }}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a single document by URI.
  """
  def get_document(uri) do
    AgentDb.read(uri)
  end

  @doc """
  Creates a new document.
  """
  def create_document(uri, content, opts \\ []) do
    AgentDb.write(uri, content, opts)
  end

  @doc """
  Updates an existing document (upsert).
  """
  def update_document(uri, content, opts \\ []) do
    AgentDb.write(uri, content, opts)
  end

  @doc """
  Deletes a document.
  """
  def delete_document(uri) do
    AgentDb.rm(uri)
  end

  @doc """
  Searches documents.
  """
  def search_documents(term, opts \\ []) do
    # Normalize opts to keyword list
    opts = 
      cond do
        is_map(opts) -> Map.to_list(opts)
        is_list(opts) -> opts
        true -> []
      end
    
    mode = get_opt(opts, "mode", :keyword)
    top_k = get_opt(opts, "top_k", "10") |> String.to_integer()
    
    AgentDb.search(term, mode: mode, top_k: top_k)
  end

  @doc """
  Lists sessions.
  """
  def list_sessions(_opts \\ []) do
    # Query sessions from the database
    # For now, return empty list - would need to implement session listing
    {:ok, []}
  end

  @doc """
  Gets a session by ID.
  """
  def get_session(id) do
    AgentDb.get_session(id)
  end

  @doc """
  Returns model status.
  """
  def model_status do
    ModelManager.model_status()
  end

  @doc """
  Returns health check status.
  """
  def health_check do
    db_check = check_db()
    model_check = check_models()
    
    %{
      status: if(db_check && model_check, do: "ok", else: "degraded"),
      checks: %{
        db: db_check,
        models: model_check
      }
    }
  end

  defp check_db do
    # Try to read a test key or list
    case AgentDb.Store.Reader.read(fn conn ->
      SQLite.query_one(conn, "SELECT 1 as health", [])
    end) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp check_models do
    status = ModelManager.model_status()
    # Consider models healthy if embedding model is loaded
    Map.get(status, :embedding, %{})[:loaded] == true
  end

  # Helper to get option from keyword list or empty list
  defp get_opt(opts, key, default) do
    # Manual lookup to avoid Keyword.get issues with empty lists
    case opts do
      [] -> default
      list when is_list(list) ->
        case Enum.find(list, fn {k, _} -> k == key end) do
          {_, value} -> value
          nil -> default
        end
      _ -> default
    end
  end
end