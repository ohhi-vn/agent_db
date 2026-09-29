# Example configuration for AgentDb
# Copy to config/runtime.exs and customize

import Config

# Compute EXLA backend
exla_backend =
  case System.get_env("AGENT_DB_EXLA_BACKEND") do
    "cuda" -> :cuda
    "rocm" -> :rocm
    _ -> :cpu
  end

# Compute HTTP auth tokens
http_auth_tokens =
  case System.get_env("AGENT_DB_HTTP_AUTH_TOKENS") do
    nil -> []
    "" -> []
    tokens -> String.split(tokens, ",", trim: true)
  end

config :agent_db,
  # Data directory
  data_dir: System.get_env("AGENT_DB_DATA_DIR") || "/path/to/data",

  # Model cache directory
  model_cache_dir: System.get_env("AGENT_DB_MODEL_CACHE_DIR") || "/path/to/models",

  # Embedding model (384-dim, fast, good quality)
  embedding_model:
    System.get_env("AGENT_DB_EMBEDDING_MODEL") || "sentence-transformers/all-MiniLM-L6-v2",
  embedding_model_url:
    System.get_env("AGENT_DB_EMBEDDING_MODEL_URL") ||
      "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/model.safetensors",

  # LLM model for summarization (Qwen3-0.6B, 0.6B params, Q4_K_M quantized)
  llm_model: System.get_env("AGENT_DB_LLM_MODEL") || "Qwen/Qwen3-0.6B",
  llm_model_url:
    System.get_env("AGENT_DB_LLM_MODEL_URL") ||
      "https://huggingface.co/tensorblock/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf",

  # Chat format for summarization prompts. Must match the configured model;
  # Bumblebee has no API that returns a model's own chat template.
  # The default below is Qwen3's ChatML. For Phi-3, use:
  #   "<|user|>\n%{prompt}<|end|>\n<|assistant|>"
  llm_chat_template:
    System.get_env("AGENT_DB_LLM_CHAT_TEMPLATE") ||
      "<|im_start|>user\n%{prompt}<|im_end|>\n<|im_start|>assistant\n",

  # Parameter size reported for the model in model status. Descriptive only.
  llm_model_params: System.get_env("AGENT_DB_LLM_MODEL_PARAMS") || "0.6B",

  # Write mode
  async_writes:
    System.get_env("AGENT_DB_ASYNC_WRITES") |> String.downcase() |> Kernel.==("true") || true,

  # Job worker pool
  job_workers:
    System.get_env("AGENT_DB_JOB_WORKERS") |> String.to_integer() || System.schedulers_online(),

  # EXLA backend
  exla_backend: exla_backend,

  # HTTP/WebSocket API
  http_enabled:
    System.get_env("AGENT_DB_HTTP_ENABLED") |> String.downcase() |> Kernel.==("true") || true,
  http_port: System.get_env("AGENT_DB_HTTP_PORT") |> String.to_integer() || 4000,
  http_auth:
    System.get_env("AGENT_DB_HTTP_AUTH") |> String.downcase() |> Kernel.==("true") || false,
  http_auth_tokens: http_auth_tokens
