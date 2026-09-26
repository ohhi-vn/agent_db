defmodule AgentDb.ML.DownloadTest do
  use ExUnit.Case, async: false

  alias AgentDb.ML.ModelManager

  @model_id "sentence-transformers/all-MiniLM-L6-v2"

  setup do
    # Swap out just this one supervised child so the rest of the tree is
    # untouched. ModelManager reads its config in init/1, so every URL change
    # has to go through replace_state.
    :ok = Supervisor.terminate_child(AgentDb.Supervisor, ModelManager)
    cache = Path.join(System.tmp_dir!(), "agent_db_dl_#{:erlang.unique_integer([:positive])}")

    Application.put_env(:agent_db, :model_cache_dir, cache)
    Application.put_env(:agent_db, :embedding_model, @model_id)
    # Keep the grace short: these tests are about the download, and a long
    # grace would outlast a retry backoff and report :model_loading instead.
    Application.put_env(:agent_db, :model_load_grace_ms, 200)

    on_exit(fn ->
      Application.delete_env(:agent_db, :model_cache_dir)
      Application.delete_env(:agent_db, :embedding_model)
      Application.delete_env(:agent_db, :embedding_model_url)
      Application.delete_env(:agent_db, :model_load_grace_ms)
      File.rm_rf(cache)
      Supervisor.restart_child(AgentDb.Supervisor, ModelManager)
    end)

    %{cache: cache}
  end

  defp model_path(cache) do
    cache |> Path.join(@model_id) |> Path.join("model.safetensors")
  end

  # The fake loader keeps these tests on the download path: with the real
  # Bumblebee loader, loading would start after the download and exceed the
  # GenServer.call budget, which is a separate concern.
  defp start_manager(url) do
    Application.put_env(:agent_db, :embedding_model_url, url)
    :ok = AgentDb.ML.FakeCallLog.start()
    start_supervised!({ModelManager, []})
    :sys.replace_state(ModelManager, fn state ->
      config = Map.merge(state.config, %{loader: AgentDb.ML.FakeLoader, embedding_model_url: url})
      %{state | config: config}
    end)

    :ok
  end

  defp set_url(url) do
    Application.put_env(:agent_db, :embedding_model_url, url)
    :sys.replace_state(ModelManager, &%{&1 | config: Map.put(&1.config, :embedding_model_url, url)})
    :ok
  end

  # A truncated transfer makes Req retry with backoff, which can outlast the
  # GenServer.call budget. Whether the caller waits or is cut off is timeout
  # policy, which this change deliberately defers; the invariant under test is
  # what the failure leaves on disk, so tolerate either outcome here.
  defp attempt_embed(text \\ "hello") do
    ModelManager.embed([text])
  catch
    :exit, _reason -> :call_timed_out
  end

  # A truncated transfer is retried by Req with backoff, so the caller may be
  # cut off before the error arrives. Both outcomes are acceptable here; the
  # requirement is what the attempt left behind and that the process survived.
  defp assert_download_failed(result) do
    # :model_loading is also acceptable: a truncated transfer is retried with
    # backoff and can outlast any grace period, leaving the caller told to
    # retry rather than given the failure. Either way nothing may be left on
    # disk, which is the invariant the caller of this helper asserts next.
    assert result == :call_timed_out or match?({:error, {:download_failed, _}}, result) or
             result == {:error, :model_loading}
  end

  # Only one load runs at a time, so a new URL cannot be tried until the
  # previous attempt has settled. Without this the next attempt legitimately
  # reports :model_loading.
  defp settle(timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_settle(deadline)
  end

  defp do_settle(deadline) do
    case GenServer.call(ModelManager, {:load_status, :embedding}, 5_000) do
      :loading ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(25)
          do_settle(deadline)
        end

      other ->
        other
    end
  end

  defp assert_no_model_files(cache) do
    refute File.exists?(model_path(cache)),
           "a partial download must never be left at the model's cache path"

    refute File.exists?(model_path(cache) <> ".part"),
           "a .part file must be cleaned up"
  end

  # A loopback HTTP server speaking just enough HTTP/1.1 for Req. `mode`
  # selects the failure being exercised.
  defp serve(mode, body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw, ip: :loopback])

    {:ok, port} = :inet.port(listen)
    parent = self()

    # Accept repeatedly: Req retries transport failures, and each retry needs a
    # served response rather than a refused connection.
    pid =
      spawn_link(fn ->
        accept_loop(listen, mode, body, parent)
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    "http://127.0.0.1:#{port}/model.safetensors"
  end

  defp accept_loop(listen, mode, body, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, _} = :gen_tcp.recv(socket, 0, 5_000)

        case mode do
          :ok ->
            header = "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n"
            :gen_tcp.send(socket, header <> body)

          :not_found ->
            :gen_tcp.send(socket, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n")

          # Promises more than it delivers, then hangs up mid-body.
          :truncated ->
            header = "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n"
            :gen_tcp.send(socket, header <> binary_part(body, 0, div(byte_size(body), 2)))
        end

        :gen_tcp.close(socket)
        send(parent, :served)
        accept_loop(listen, mode, body, parent)

      {:error, _} ->
        :ok
    end
  end

  describe "a successful download" do
    test "writes the body to the model path and leaves no partial file", %{cache: cache} do
      body = :crypto.strong_rand_bytes(4096)
      :ok = start_manager(serve(:ok, body))

      assert {:ok, _} = ModelManager.embed(["hello"])
      assert File.read!(model_path(cache)) == body
      refute File.exists?(model_path(cache) <> ".part")
    end
  end

  describe "a failed download" do
    test "an HTTP error status leaves nothing at the model path", %{cache: cache} do
      :ok = start_manager(serve(:not_found, ""))

      assert {:error, {:download_failed, 404}} = ModelManager.embed(["hello"])
      assert_no_model_files(cache)
    end

    test "a truncated response leaves nothing at the model path", %{cache: cache} do
      :ok = start_manager(serve(:truncated, :crypto.strong_rand_bytes(4096)))

      assert_download_failed(attempt_embed())
      assert_no_model_files(cache)
    end

    test "a later request retries rather than trusting a partial file", %{cache: cache} do
      :ok = start_manager(serve(:truncated, :crypto.strong_rand_bytes(4096)))

      assert_download_failed(attempt_embed())
      settle()
      assert_no_model_files(cache)
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()

      :ok = set_url(serve(:ok, "weights"))
      assert {:ok, _} = ModelManager.embed(["hello"])
      assert File.read!(model_path(cache)) == "weights"
    end
  end

  describe "the inference process" do
    test "survives every download failure mode and stays responsive", %{cache: cache} do
      # A bad host: a transport failure, which is what used to kill this process
      # because Req.get!/1 raised outside the try.
      :ok = start_manager("http://127.0.0.1:1/unreachable")

      assert_download_failed(attempt_embed())
      settle()
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()

      :ok = set_url(serve(:not_found, ""))
      assert {:error, {:download_failed, 404}} = ModelManager.embed(["hello"])
      settle()
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()

      :ok = set_url(serve(:truncated, :crypto.strong_rand_bytes(1024)))
      assert_download_failed(attempt_embed())
      settle()
      assert %{embedding: %{loaded: false}} = ModelManager.model_status()

      assert_no_model_files(cache)
    end
  end
end
