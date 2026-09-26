defmodule AgentDb.ML.ModelManager.State do
  @moduledoc "State struct for ModelManager"

  @type model_ref :: %{
          tokenizer: Bumblebee.Tokenizer.t(),
          model: Bumblebee.Model.t(),
          config: map(),
          serving: module()
        }

  @type load_status :: :idle | :loading | :ready | :failed

  @type t :: %__MODULE__{
          embedding_model: model_ref() | nil,
          llm_model: model_ref() | nil,
          loading: %{optional(:embedding) => load_status(), optional(:llm) => load_status()},
          loading_ref: reference() | nil,
          config: map()
        }

  defstruct [
    embedding_model: nil,
    llm_model: nil,
    loading: %{embedding: :idle, llm: :idle},
    loading_ref: nil,
    config: %{}
  ]
end
