# Example configuration for AgentDb
# Copy to config/runtime.exs and customize
#
# Every setting below has a working default, so this file evaluates with no
# environment set at all. A variable that is set is parsed as its own type, and
# an unparseable value is refused by name rather than silently ignored.

import Config

# An environment variable as a trimmed string, or `nil` when unset or blank, so
# that "set to empty" is treated the same as "not set" instead of parsing "".
env = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
  end
end

# An environment variable as a boolean, where only "true"/"1"/"yes" enable it.
# Unset is nil rather than false, so that "not configured" reaches the store as
# absent and its own default decides.
env_bool = fn name ->
  case env.(name) do
    nil -> nil
    value -> value in ~w(true 1 yes)
  end
end

# An environment variable as an integer, refusing a value that is not one.
env_int = fn name ->
  case env.(name) do
    nil ->
      nil

    value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> raise "#{name} must be an integer, got: #{inspect(value)}"
      end
  end
end

# The provider as one of the values `AgentDb.Runtime` recognizes. Unset is
# left absent; an unrecognized value is passed through as written so that
# startup validation is what refuses it, naming what was configured.
inference_provider = fn
  nil -> nil
  "local" -> :local
  "ollama" -> :ollama
  "openai_compatible" -> :openai_compatible
  other -> other
end

# A setting that no environment variable supplied is left out entirely, rather
# than written as nil: a key present with the value nil would be a configured
# answer, and would override the default the store would otherwise use.
setting = fn name, value -> if value == nil, do: nil, else: {name, value} end

settings =
  [
    setting.(:data_dir, env.("AGENT_DB_DATA_DIR") || Path.expand("../data", __DIR__)),
    setting.(
      :model_cache_dir,
      env.("AGENT_DB_MODEL_CACHE_DIR") || Path.expand("../data/models", __DIR__)
    ),

    # Embedding model (384-dim, fast, good quality)
    setting.(
      :embedding_model,
      env.("AGENT_DB_EMBEDDING_MODEL") || "sentence-transformers/all-MiniLM-L6-v2"
    ),
    setting.(
      :embedding_model_url,
      env.("AGENT_DB_EMBEDDING_MODEL_URL") ||
        "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/model.safetensors"
    ),

    # LLM model for summarization (Qwen3-0.6B, 0.6B params, Q4_K_M quantized)
    setting.(:llm_model, env.("AGENT_DB_LLM_MODEL") || "Qwen/Qwen3-0.6B"),
    setting.(
      :llm_model_url,
      env.("AGENT_DB_LLM_MODEL_URL") ||
        "https://huggingface.co/tensorblock/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
    ),

    # Chat format for summarization prompts. Must match the configured model;
    # Bumblebee has no API that returns a model's own chat template. The default
    # below is Qwen3's ChatML. For Phi-3, use:
    #   "<|user|>\n%{prompt}<|end|>\n<|assistant|>"
    setting.(
      :llm_chat_template,
      env.("AGENT_DB_LLM_CHAT_TEMPLATE") || "user\n%{prompt}\nassistant\n"
    ),

    # Parameter size reported for the model in model status. Descriptive only.
    setting.(:llm_model_params, env.("AGENT_DB_LLM_MODEL_PARAMS") || "0.6B"),

    # Which provider serves embed/1 and summarize/2, and the provider kind
    # model_status/0 reports. One key, so the two cannot disagree. `:local`
    # (in-process Nx/Bumblebee), `:ollama`, `:openai_compatible`, or a module
    # implementing AgentDb.Core.Inference. An unrecognized value is left as it
    # was given so that startup names it rather than this file guessing.
    setting.(:inference_provider, inference_provider.(env.("AGENT_DB_INFERENCE_PROVIDER"))),

    # Write mode
    setting.(:async_writes, env_bool.("AGENT_DB_ASYNC_WRITES")),

    # Job worker pool
    setting.(:job_workers, env_int.("AGENT_DB_JOB_WORKERS") || System.schedulers_online()),

    # EXLA backend
    setting.(
      :exla_backend,
      case env.("AGENT_DB_EXLA_BACKEND") do
        "cuda" -> :cuda
        "rocm" -> :rocm
        _ -> :cpu
      end
    ),

    # HTTP/WebSocket API
    setting.(:http_enabled, env_bool.("AGENT_DB_HTTP_ENABLED")),
    setting.(:http_port, env_int.("AGENT_DB_HTTP_PORT") || 6060),
    setting.(:http_auth, env_bool.("AGENT_DB_HTTP_AUTH") || false),
    setting.(
      :http_auth_tokens,
      case env.("AGENT_DB_HTTP_AUTH_TOKENS") do
        nil ->
          []

        tokens ->
          tokens |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end
    )
  ]
  |> Enum.reject(&is_nil/1)

config :agent_db, settings
