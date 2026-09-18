defmodule AgentDb.ML.ModelManager.State do
  @moduledoc "State struct for ModelManager"

  @type model_ref :: %{
          tokenizer: Bumblebee.Tokenizer.t(),
          model: Bumblebee.Model.t(),
          config: map(),
          serving: module()
        }

  @type t :: %__MODULE__{
          embedding_model: model_ref() | nil,
          llm_model: model_ref() | nil,
          loading: map(),
          config: map()
        }

  defstruct [
    embedding_model: nil,
    llm_model: nil,
    loading: %{},
    config: %{}
  ]
end