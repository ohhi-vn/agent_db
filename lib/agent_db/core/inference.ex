defmodule AgentDb.Core.Inference do
  @moduledoc """
  The local model capabilities the store depends on.

  Split by capability rather than by "run a model", so a workflow asks for
  exactly what it needs and a provider need only supply part of the surface.
  Embedding and summarization are separate callbacks because they have
  different failure modes: a document's embedding is what makes it findable
  by meaning, while a summary is a compression of something already readable.

  ## Invariants an implementation must uphold

    * `embed/1` returns vectors that are comparable with each other and stable
      for identical input, so an index built from them stays meaningful.
    * A model that is still loading is reported as loading, distinctly from a
      load that failed. `{:error, :model_loading}` is safe to repeat; a failure
      is not, and must not be disguised as one.
    * Neither an unavailable model nor a failed inference terminates the
      calling process or leaves the provider permanently unusable.
  """

  @typedoc "A query or document embedding, as float32 bytes."
  @type embedding :: binary()

  @doc "Supervised children the provider needs."
  @callback child_specs(keyword()) :: [Supervisor.child_spec() | module() | {module(), term()}]

  @doc "Embeds `texts`, returning one comparable vector per input."
  @callback embed([String.t()]) :: {:ok, [embedding()]} | {:error, term()}

  @doc "Summarizes `prompt`. An empty answer is an error, not an empty summary."
  @callback summarize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Describes the state of both models, including a load in progress.

  Answerable while a load is running, so a caller can tell "still coming" from
  "not there".
  """
  @callback model_status() :: map()
end
