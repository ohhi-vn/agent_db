defmodule AgentDb.ML.ModelManager.State do
  @moduledoc "State struct for ModelManager"

  @type model_ref :: %{
          tokenizer: Bumblebee.Tokenizer.t(),
          model: Bumblebee.Model.t(),
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

  @type t :: %__MODULE__{
          embedding_model: model_ref() | nil,
          llm_model: model_ref() | nil,
          loading: %{optional(:embedding) => load_status(), optional(:llm) => load_status()},
          loading_ref: loading_ref(),
          config: map()
        }

  defstruct embedding_model: nil,
            llm_model: nil,
            loading: %{embedding: :idle, llm: :idle},
            loading_ref: %{},
            config: %{}
end
