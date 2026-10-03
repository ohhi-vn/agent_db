defmodule AgentDb.ML.ModelDownload do
  @moduledoc false

  # Fetching model weights into the local cache, and nothing else.
  #
  # The manager decides *when* a model is needed; this module owns *how* its
  # files get onto disk: the `.part`-then-rename protocol, the test-environment
  # network guard, and the redacted operational logging around both.

  @download_receive_timeout 30_000

  @doc "Ensures the weight file for `model_id` is present under `cache_dir`, downloading it from `model_url` when absent."
  @spec ensure_model_files(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_model_files(model_id, model_url, cache_dir) do
    model_dir = Path.join(cache_dir, model_id)
    model_file = Path.join(model_dir, "model.safetensors")

    if File.exists?(model_file) do
      :ok
    else
      download_model(model_url, model_dir, model_file)
    end
  end

  # Writes to a .part path and renames into place, so a file at model_file is
  # proof of a completed download. Previously the body was written straight to
  # the final path, so a truncated file satisfied File.exists?/1 on every
  # later boot and then failed at load forever.
  defp download_model(url, model_dir, model_file) do
    if skip_remote_download_in_test?(url) do
      {:error, {:model_not_found, model_file}}
    else
      do_download_model(url, model_dir, model_file)
    end
  end

  # Keep the test suite off the network without also blocking the load path or
  # the download logic itself: loopback URLs are served by the test and are
  # always attempted.
  defp skip_remote_download_in_test?(url) do
    Mix.env() == :test and not String.starts_with?(url, "http://127.0.0.1")
  end

  defp do_download_model(url, model_dir, model_file) do
    partial = model_file <> ".part"
    File.mkdir_p!(model_dir)

    AgentDb.Observability.log(:info, component: :model, operation: :download, outcome: :started)

    case Req.get(url, receive_timeout: @download_receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        File.write!(partial, body)
        File.rename!(partial, model_file)
        AgentDb.Observability.log(:info, component: :model, operation: :download, outcome: :ok)
        :ok

      {:ok, %Req.Response{status: status}} ->
        AgentDb.Observability.log(:error,
          component: :model,
          operation: :download,
          outcome: :error,
          reason: {:download_failed, status}
        )

        {:error, {:download_failed, status}}

      {:error, reason} ->
        AgentDb.Observability.log(:error,
          component: :model,
          operation: :download,
          outcome: :error,
          reason: {:download_failed, :transport}
        )

        {:error, {:download_failed, reason}}
    end
    |> case do
      :ok ->
        :ok

      {:error, _} = error ->
        # Leave nothing behind that a later run would treat as a usable cache.
        File.rm(partial)
        error
    end
  end
end
