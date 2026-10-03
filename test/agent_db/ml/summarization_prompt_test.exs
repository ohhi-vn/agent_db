defmodule AgentDb.ML.SummarizationPromptTest do
  @moduledoc """
  Covers the prompt format, reasoning handling, and reported model size for the
  summarization model.
  """
  use ExUnit.Case, async: false

  alias AgentDb.ML.{FakeCallLog, FakeLoader, FakeServing, ModelManager}

  @llm_id "Qwen/Qwen3-0.6B"

  @custom_template "CUSTOM>>%{prompt}<<CUSTOM"

  setup do
    :ok = Supervisor.terminate_child(AgentDb.Supervisor, ModelManager)

    # The call log records every prompt sent to the fake serving, including the
    # ones a worker sends while summarizing something it was already given. A
    # worker running here would put an unrelated prompt in the middle of what
    # this test is asserting about.
    :ok = AgentDb.StorageContract.Helpers.stop_workers()

    cache = AgentDb.Test.Scratch.dir("agent_db_sum")

    Application.put_env(:agent_db, :model_cache_dir, cache)
    Application.put_env(:agent_db, :llm_model, @llm_id)
    Application.put_env(:agent_db, :llm_model_params, "0.6B")
    Application.put_env(:agent_db, :model_load_grace_ms, 5_000)

    on_exit(fn ->
      for key <- [:model_cache_dir, :llm_model, :llm_model_params, :model_load_grace_ms] do
        Application.delete_env(:agent_db, key)
      end

      FakeServing.clear_generated_text()
      File.rm_rf(cache)
      AgentDb.StorageContract.Helpers.restore_child(ModelManager)

      for worker <- [AgentDb.Workers.Embedding, AgentDb.Workers.Summarization] do
        AgentDb.StorageContract.Helpers.restore_child(worker)
      end
    end)

    cache_llm(cache)
    :ok = FakeCallLog.start()
    :ok

    %{cache: cache}
  end

  # A cached weights file means the load skips the download and runs.
  defp cache_llm(cache) do
    dir = Path.join(cache, @llm_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "model.safetensors"), "not-real-weights")
    :ok
  end

  # The template is supplied through the manager's config, which is the same
  # seam the loader is swapped through.
  defp start_manager(chat_template) do
    start_supervised!({ModelManager, []})

    :sys.replace_state(ModelManager, fn state ->
      config =
        state.config
        |> Map.put(:loader, FakeLoader)
        |> Map.put(:llm_chat_template, chat_template)

      %{state | config: config}
    end)
  end

  defp prompts, do: for({prompt, _} <- FakeCallLog.entries(:prompt), do: prompt)

  describe "the prompt format comes from configuration" do
    test "a configured template is applied to the prompt" do
      start_manager(@custom_template)
      FakeCallLog.clear()

      assert {:ok, _} = ModelManager.summarize("the user prompt")

      assert ["CUSTOM>>the user prompt<<CUSTOM"] = prompts()
    end

    test "a different template produces a different prompt" do
      # The same summarization request under a second configured format must
      # not be answered with the first format's markers.
      start_manager("<|im_start|>user\n%{prompt}<|im_end|>\n<|im_start|>assistant\n")
      FakeCallLog.clear()

      assert {:ok, _} = ModelManager.summarize("hello")

      assert ["<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n"] = prompts()
    end
  end

  describe "a generated summary excludes the model's reasoning" do
    test "reasoning is removed and the answer is returned" do
      start_manager(@custom_template)

      FakeServing.put_generated_text(
        "<think>The user wants a summary. I will write one.</think>The document is about tests."
      )

      assert {:ok, "The document is about tests."} = ModelManager.summarize("summarize")
    end

    test "multiline reasoning is removed entirely" do
      start_manager(@custom_template)

      FakeServing.put_generated_text(
        "<think>\nfirst thought\nsecond thought\n</think>\n\nThe short answer."
      )

      assert {:ok, "The short answer."} = ModelManager.summarize("summarize")
    end

    test "output with no reasoning is returned unchanged" do
      start_manager(@custom_template)
      FakeServing.put_generated_text("A plain answer with no reasoning.")

      assert {:ok, "A plain answer with no reasoning."} = ModelManager.summarize("summarize")
    end
  end

  describe "a generation with no answer is an error" do
    test "an unterminated reasoning block reports an error" do
      # The model spent its whole token budget reasoning. The reasoning is not
      # a summary, and returning it as one would be worse than failing.
      start_manager(@custom_template)
      FakeServing.put_generated_text("<think>still thinking when the budget ran out")

      assert {:error, {:empty_summary, :no_answer}} = ModelManager.summarize("summarize")
    end

    test "a closed reasoning block with nothing after it reports an error" do
      start_manager(@custom_template)
      FakeServing.put_generated_text("<think>all reasoning, no answer</think>")

      assert {:error, {:empty_summary, :no_answer}} = ModelManager.summarize("summarize")
    end

    test "whitespace alone after reasoning reports an error" do
      start_manager(@custom_template)
      FakeServing.put_generated_text("<think>reasoning</think>\n\n   \n")

      assert {:error, {:empty_summary, :no_answer}} = ModelManager.summarize("summarize")
    end

    test "an empty generation reports an error rather than an empty summary" do
      # "" is truthy, so storing it would permanently defeat the first-line
      # fallback in AgentDb.abstract/1.
      start_manager(@custom_template)
      FakeServing.put_generated_text("")

      assert {:error, {:empty_summary, :no_answer}} = ModelManager.summarize("summarize")
    end
  end

  describe "model status reports the configured size" do
    test "reports the configured parameter size" do
      start_manager(@custom_template)
      Application.put_env(:agent_db, :llm_model_params, "12.7B")

      # The manager snapshots config at init, so a fresh one picks this up.
      stop_supervised!(ModelManager)
      Application.put_env(:agent_db, :llm_model_params, "12.7B")
      start_supervised!({ModelManager, []})

      assert %{llm: %{params: "12.7B"}} = ModelManager.model_status()
    end

    test "does not report a size belonging to a different model" do
      start_manager(@custom_template)

      assert %{llm: %{params: "0.6B"}} = ModelManager.model_status()
    end
  end
end
