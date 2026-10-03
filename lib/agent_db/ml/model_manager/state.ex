defmodule AgentDb.ML.ModelManager.State do
  @moduledoc "State struct for ModelManager"

  @type model_ref :: %{
          tokenizer: Bumblebee.Tokenizer.t(),
          model: term(),
          config: map(),
          serving: module(),
          chat_template: String.t()
        }

  @type load_status :: :idle | :loading | :ready | :failed

  # Keyed by role, not a single reference. The embedding and summarization
  # models load independently and often at the same time; one shared reference
  # would let the second load discard the first load's result, leaving that
  # role reporting as loading forever.
  @type loading_ref :: %{optional(:embedding) => reference(), optional(:llm) => reference()}

  # A load is the one long operation an operator waits on and cannot otherwise
  # see, so its duration is kept the way inference latency is: per role, last
  # run only.
  @type last_load_ms :: %{optional(:embedding | :llm) => non_neg_integer()}

  # A run reads the model without changing it, so several may be in flight.
  # `in_flight` bounds them: past `Config.inference_concurrency/0` the manager
  # runs inline rather than starting a process it has no room for.
  @type t :: %__MODULE__{
          embedding_model: model_ref() | nil,
          llm_model: model_ref() | nil,
          loading: %{optional(:embedding) => load_status(), optional(:llm) => load_status()},
          loading_ref: loading_ref(),
          last_latency_ms: %{optional(:embedding | :llm) => non_neg_integer()},
          last_load_ms: %{optional(:embedding | :llm) => non_neg_integer()},
          in_flight: non_neg_integer(),
          inference_refs: MapSet.t(reference()),
          config: map()
        }

  defstruct embedding_model: nil,
            llm_model: nil,
            loading: %{embedding: :idle, llm: :idle},
            loading_ref: %{},
            last_latency_ms: %{},
            last_load_ms: %{},
            in_flight: 0,
            inference_refs: MapSet.new(),
            config: %{}
end
