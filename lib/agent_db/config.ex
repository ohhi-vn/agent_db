defmodule AgentDb.Config do
  @moduledoc false

  # Runtime configuration for the store. All keys read at call time so the
  # library consumer can configure after compilation (library rule).

  @spec data_dir() :: String.t()
  def data_dir do
    Application.get_env(:agent_db, :data_dir) || Path.join(File.cwd!(), "data")
  end

  @spec model_cache_dir() :: String.t()
  def model_cache_dir do
    Application.get_env(:agent_db, :model_cache_dir) ||
      Path.join(File.cwd!(), "models")
  end

  @spec embedding_model() :: String.t()
  def embedding_model do
    Application.get_env(:agent_db, :embedding_model) ||
      "sentence-transformers/all-MiniLM-L6-v2"
  end

  @spec embedding_model_url() :: String.t()
  def embedding_model_url do
    Application.get_env(:agent_db, :embedding_model_url) ||
      "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/model.safetensors"
  end

  @spec llm_model() :: String.t()
  def llm_model do
    Application.get_env(:agent_db, :llm_model) ||
      "Qwen/Qwen3-0.6B"
  end

  @spec llm_model_url() :: String.t()
  def llm_model_url do
    Application.get_env(:agent_db, :llm_model_url) ||
      "https://huggingface.co/tensorblock/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
  end

  @doc """
  Chat format used to present prompts to the summarization model.

  A single template string with a `%{prompt}` placeholder. It is configuration
  rather than a literal in the inference path because the prompt format belongs
  to the model, not to the store: Bumblebee exposes no chat-template API, so the
  value cannot be read back from the loaded model and has to be supplied here.

  The default is Qwen3's ChatML. Set this to the format of whatever model is
  configured through `llm_model/0` -- for Phi-3, for example,
  `"<|user|>\\n%{prompt}<|end|>\\n<|assistant|>"`.
  """
  @spec llm_chat_template() :: String.t()
  def llm_chat_template do
    Application.get_env(:agent_db, :llm_chat_template) ||
      "<|im_start|>user\n%{prompt}<|im_end|>\n<|im_start|>assistant\n"
  end

  @doc """
  Parameter size reported for the summarization model in model status.

  Descriptive metadata, not something the store can derive from a weight file,
  so it is configured alongside the model it describes.
  """
  @spec llm_model_params() :: String.t()
  def llm_model_params do
    Application.get_env(:agent_db, :llm_model_params) || "0.6B"
  end

  @spec async_writes() :: boolean()
  def async_writes do
    Application.get_env(:agent_db, :async_writes, true)
  end

  @spec job_workers() :: pos_integer()
  def job_workers do
    Application.get_env(:agent_db, :job_workers, System.schedulers_online())
  end

  @spec exla_backend() :: :cpu | :cuda | :rocm
  def exla_backend do
    Application.get_env(:agent_db, :exla_backend, :cpu)
  end

  @doc """
  How long a model-dependent call waits for a lazy load to finish before
  reporting that the model is still loading.

  Loading is lazy, and the two paths differ by an order of magnitude: a warm
  load from cached weights measures ~3.3s, while a cold first use including the
  download measures ~37s. The default covers the warm path so an already-cached
  model is invisible to the caller; a longer cold load reports
  `{:error, :model_loading}` instead of blocking.
  """
  @spec model_load_grace_ms() :: pos_integer()
  def model_load_grace_ms do
    Application.get_env(:agent_db, :model_load_grace_ms, 10_000)
  end

  @spec http_enabled() :: boolean()
  def http_enabled do
    Application.get_env(:agent_db, :http_enabled, true)
  end

  @doc """
  Interface the HTTP listener binds to.

  Loopback by default. The endpoint's own configuration is what actually binds;
  this reports the resolved value, so application code and tests can ask which
  interface is in force without duplicating the default or reading config.
  """
  @spec http_ip() :: :inet.ip_address()
  def http_ip do
    Application.get_env(:agent_db, :http_ip, {127, 0, 0, 1})
  end

  @spec http_auth() :: boolean()
  def http_auth do
    Application.get_env(:agent_db, :http_auth, false)
  end

  @spec http_auth_tokens() :: [String.t()]
  def http_auth_tokens do
    Application.get_env(:agent_db, :http_auth_tokens, [])
  end

  @doc """
  How long shutdown waits for work already claimed to finish.

  Bounded, so a store whose workers are stuck on an unreachable model still
  stops. Anything left unfinished is a row in the queue, recovered by the next
  boot rather than lost.
  """
  @spec shutdown_grace_ms() :: pos_integer()
  def shutdown_grace_ms do
    Application.get_env(:agent_db, :shutdown_grace_ms, 5_000)
  end

  @doc "Test helper: private per-test data dir under the system tmp dir."
  @spec test_data_dir() :: String.t()
  def test_data_dir do
    # unique_integer is per-VM; mix test spins up many VMs whose counters
    # overlap, so salt with monotonic time + PID for cross-run uniqueness.
    Path.join(
      System.tmp_dir!(),
      "agent_db_data_#{:erlang.unique_integer([:positive])}_#{System.system_time(:native)}_#{:erlang.phash2(self())}"
    )
  end
end
