defmodule AgentDb.ML.FakeServing do
  @moduledoc false
  # Stands in for Bumblebee's built servings so inference can run without real
  # weights. The real loader builds an Nx.Serving and runs it; this builds a
  # tagged value and answers from it, so the backend code under test is the
  # same in both cases.

  @generated_text_key :fake_generated_text

  def put_generated_text(text), do: Application.put_env(:agent_db, @generated_text_key, text)

  def clear_generated_text, do: Application.delete_env(:agent_db, @generated_text_key)

  def generated_text,
    do: Application.get_env(:agent_db, @generated_text_key, "generated summary")

  def build(:embedding, _model_info, _tokenizer, _opts),
    do: {:ok, %{serving: :embedding}}

  def build(:llm, _model_info, _tokenizer, _opts), do: {:ok, %{serving: :llm}}

  def run(%{serving: :embedding}, texts) when is_list(texts) do
    # The real serving pools and L2-normalizes before returning, so each
    # embedding here is already a unit vector of the same shape.
    {:ok,
     Enum.map(texts, fn text ->
       tensor = Nx.tensor([String.length(text) * 1.0, 2.0])
       norm = Nx.sqrt(Nx.sum(Nx.pow(tensor, 2)))
       Nx.divide(tensor, norm)
     end)}
  end

  def run(%{serving: :llm}, prompt) when is_binary(prompt) do
    # The prompt is recorded here because this is where the formatted prompt
    # arrives, letting a test assert on the chat format the store built rather
    # than on a string it constructed itself.
    AgentDb.ML.FakeCallLog.record(:prompt, prompt, [])
    {:ok, %{results: [%{text: generated_text()}]}}
  end
end

defmodule AgentDb.ML.FakeCallLog do
  @moduledoc false
  # Records what a fake loader was asked for. The loader runs inside the
  # ModelManager process, so a message would land in the GenServer's mailbox
  # rather than the test's.

  @table :agent_db_fake_loader_calls

  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:public, :named_table, :duplicate_bag])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  # Tolerates the table being gone: a load spawned by a finished test can
  # outlive the test process that owned the table.
  def clear, do: :ets.delete_all_objects(@table)

  def record(kind, subject, opts) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> :ets.insert(@table, {kind, subject, opts})
    end
  end

  def entries(kind) do
    case :ets.whereis(@table) do
      :undefined -> []
      _tid -> :ets.select(@table, [{{kind, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    end
  end
end

defmodule AgentDb.ML.FakeLoader do
  @moduledoc false
  # Stands in for the model-loading library so the load path can be driven
  # without real weights.

  def load_tokenizer({:hf, model_id}) do
    AgentDb.ML.FakeCallLog.record(:load_tokenizer, model_id, [])
    {:ok, {:tokenizer, model_id}}
  end

  def load_model({:hf, model_id}, opts) do
    AgentDb.ML.FakeCallLog.record(:load_model, model_id, opts)
    {:ok, %{model: {:model, model_id}, spec: {:spec, model_id}}}
  end

  def build_serving(role, model_info, tokenizer, opts),
    do: AgentDb.ML.FakeServing.build(role, model_info, tokenizer, opts)

  def run(serving, input), do: AgentDb.ML.FakeServing.run(serving, input)
end

defmodule AgentDb.ML.FakeBumblebee do
  @moduledoc false
  # Stands in for the Bumblebee module so BumblebeeLoader's repository and
  # backend handling can be asserted without real weights.

  def load_tokenizer(repository) do
    AgentDb.ML.FakeCallLog.record(:load_tokenizer, repository, [])
    {:ok, {:tokenizer, repository}}
  end

  def load_model(repository, opts) do
    AgentDb.ML.FakeCallLog.record(:load_model, repository, opts)
    {:ok, %{model: {:model, repository}, spec: {:spec, repository}}}
  end
end

defmodule AgentDb.ML.RaisingLoader do
  @moduledoc false
  # A loader that blows up, standing in for the transport and library failures
  # that must be reported rather than propagated.

  def load_tokenizer(_), do: raise("tokenizer unavailable")
  def load_model(_, _), do: raise("model unavailable")
  def build_serving(_, _, _, _), do: raise("serving unavailable")
  def run(_, _), do: raise("serving unavailable")
end

defmodule AgentDb.ML.ExitingLoader do
  @moduledoc false
  # A loader that exits rather than raising. EXLA.Client reports a missing
  # platform this way, and an exit is not covered by `rescue`.

  def load_tokenizer(_), do: exit(:no_such_client)
  def load_model(_, _), do: exit(:no_such_client)
  def build_serving(_, _, _, _), do: exit(:no_such_client)
  def run(_, _), do: exit(:no_such_client)
end

defmodule AgentDb.ML.SlowLoader do
  @moduledoc false
  # A loader slow enough that no practical grace period covers it, standing in
  # for a cold download. Lets the :model_loading state be observed directly.

  @delay_ms 1_500

  def load_tokenizer({:hf, model_id}) do
    Process.sleep(@delay_ms)
    {:ok, {:tokenizer, model_id}}
  end

  def load_model({:hf, model_id}, opts) do
    Process.sleep(@delay_ms)
    AgentDb.ML.FakeCallLog.record(:load_model, model_id, opts)
    {:ok, %{model: {:model, model_id}, spec: {:spec, model_id}}}
  end

  def build_serving(role, model_info, tokenizer, opts),
    do: AgentDb.ML.FakeServing.build(role, model_info, tokenizer, opts)

  def run(serving, input), do: AgentDb.ML.FakeServing.run(serving, input)
end
