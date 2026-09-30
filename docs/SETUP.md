# Setup

Full install, configuration, and verification for operators. For the 5-minute
path, start at `docs/QUICKSTART.md`.

## Prerequisites

- Elixir 1.20+ with `mix` and Erlang/OTP
- `curl` (daemon and MCP checks)
- SQLite ships via `exqlite` — no separate install
- EXLA CPU works out of the box; `:cuda` / `:rocm` need a matching
  `config :exla, clients` entry or model load fails instead of falling back

Check:

```bash
elixir --version
mix deps.get
```

## Data and model directories

| Setting | Env | Default |
|---------|-----|---------|
| `data_dir` | `AGENT_DB_DATA_DIR` (see `config/example.exs`) | `./data` |
| `model_cache_dir` | `AGENT_DB_MODEL_CACHE_DIR` | `./models` |

The store keeps `agent_db.db` (WAL mode) under `data_dir` and downloads
weights into `model_cache_dir`. Both are created on boot. Sources of truth:
`AgentDb.Config.data_dir/0`, `model_cache_dir/0`, `AgentDb.Application`.

## Environment reference

All values below match `lib/agent_db/application.ex` and
`config/runtime.exs` at the time of writing.

| Config key | Env var | Default |
|------------|---------|---------|
| `embedding_model` | `AGENT_DB_EMBEDDING_MODEL` | `sentence-transformers/all-MiniLM-L6-v2` |
| `embedding_model_url` | `AGENT_DB_EMBEDDING_MODEL_URL` | HuggingFace `model.safetensors` URL |
| `llm_model` | `AGENT_DB_LLM_MODEL` | `Qwen/Qwen3-0.6B` |
| `llm_model_url` | `AGENT_DB_LLM_MODEL_URL` | HuggingFace `Qwen3-0.6B-Q4_K_M.gguf` URL |
| `llm_chat_template` | `AGENT_DB_LLM_CHAT_TEMPLATE` | Qwen3 ChatML with `%{prompt}` placeholder |
| `llm_model_params` | `AGENT_DB_LLM_MODEL_PARAMS` | `0.6B` (descriptive only, shown in model status) |
| `async_writes` | `AGENT_DB_ASYNC_WRITES` | `true` (`"true"` → true, anything else → false) |
| `job_workers` | `AGENT_DB_JOB_WORKERS` | CPU cores (`System.schedulers_online()`); must be a positive integer |
| `exla_backend` | `AGENT_DB_EXLA_BACKEND` | `cpu` (`cpu` \| `cuda` \| `rocm`; anything else → `:cpu`) |
| `ml_backend` | `AGENT_DB_ML_BACKEND` | `auto` (`auto` \| `exla` \| `emlx`; anything else → `:auto`) |
| `inference_provider` | — (Application env `:inference_provider`) | `:local` (`:local` \| `:ollama` \| `:openai_compatible` \| custom module) |
| `ollama_base_url` | `AGENT_DB_OLLAMA_URL` | `http://localhost:11434` |
| `ollama_embed_model` / `ollama_llm_model` | Application env only | `nomic-embed-text` / `llama3.1` |
| `openai_base_url` | `AGENT_DB_OPENAI_BASE_URL` | none (required for `:openai_compatible`) |
| `openai_api_key` | `AGENT_DB_OPENAI_API_KEY` | none (never logged) |
| `http_enabled` | `AGENT_DB_HTTP_ENABLED` | `true` (`false` in `:test`) |
| `http_auth` | `AGENT_DB_HTTP_AUTH` | `false` |
| `http_auth_tokens` | `AGENT_DB_HTTP_AUTH_TOKENS` | `[]` (comma-separated, e.g. `tok1,tok2`) |

Listener (resolved once in `config/runtime.exs` for both bind and URL
generation):

| Env var | Default | Meaning |
|---------|---------|---------|
| `AGENT_DB_HTTP_PORT` | `6060` | Port served and used for URL generation |
| `AGENT_DB_HTTP_IP` | `127.0.0.1` | Interface bound (loopback by default) |
| `AGENT_DB_HTTP_ENABLED` | `true` (`false` in `:test`) | Whether the endpoint is started |
| `PHX_HOST` | `localhost` | Host used for URL generation only |
| `SECRET_KEY_BASE` | dev default in `config/config.exs` | Required in prod; must be 64+ bytes or `/admin` returns 500 |
| `PORT` | — | Not read; set `AGENT_DB_HTTP_PORT` instead |

## HTTP listener and auth

The endpoint sets `server: true` in `config/runtime.exs` — without it Phoenix
binds nothing under `mix`/`iex`. The bind defaults to loopback because the
surface is unauthenticated by design and exposes document and memory content.

```bash
# loopback only (default)
iex -S mix

# LAN (bind explicitly, enable Bearer, keep the port off wider networks)
AGENT_DB_HTTP_ENABLED=true AGENT_DB_HTTP_IP=0.0.0.0 AGENT_DB_HTTP_PORT=6060 iex -S mix

# with auth
AGENT_DB_HTTP_AUTH=true AGENT_DB_HTTP_AUTH_TOKENS=<token> iex -S mix
```

Comma-separated tokens are split on `,` with whitespace trimmed. Serve beyond
loopback only with Bearer enabled.

## Backends (Apple Silicon, CUDA)

- `AGENT_DB_ML_BACKEND=auto` prefers EMLX on Apple Silicon macOS, EXLA
  elsewhere. `emlx` forces EMLX with EXLA fallback plus a warning;
  `exla` pins EXLA for CI and debugging.
- EMLX packages are `optional: true, runtime: false` and macOS-only; they are
  never fetched on Linux CI and start only when needed.
- `AGENT_DB_EXLA_BACKEND=cuda` (or `rocm`) requires a matching
  `config :exla, clients` entry — load fails loudly instead of silently using CPU.

```bash
AGENT_DB_ML_BACKEND=emlx iex -S mix
AGENT_DB_ML_BACKEND=exla mix test
```

## Models: pre-placement and cache recovery

Models auto-download on first use. To pre-place, put the files in
`model_cache_dir` before first inference.

- Downloads write to a temp path then rename, so a present file is normally
  complete. A `model.safetensors` left by an interrupted older download can
  still be truncated.
- If model loading fails: delete the file and let it re-download. Presence is
  the only cache check.
- Models load lazily. A call before readiness waits up to `model_load_grace_ms`
  (default 10s) then returns `{:error, :model_loading}` — retry later. A real
  failure returns `{:error, reason}` without killing the caller.
- `AgentDb.model_status/0` reports `:loading | :ready | :failed | :idle` and
  stays answerable throughout.

## Windows (WSL2)

Run the daemon and installer inside WSL2; point Windows editors at
`http://localhost:6060/mcp`. From PowerShell:

```powershell
wsl bash tools/install.sh --check
```

`tools/install.ps1` refuses native execution on purpose — native Windows has
no supported EXLA path.

## Verification and recovery

```bash
tools/install.sh --check
mix agent_db.doctor
```

`tools/install.sh --check` verifies Elixir/mix/curl, required files
(`mix.exs`, `config/runtime.exs`, MCP modules), daemon reachability at
`/api/v1/health`, and MCP `tools/list` containing `context_read`.

| Failure | Fix |
|---------|-----|
| `missing: elixir/mix/curl` | Install per the hint (`brew install elixir`, `apt install elixir`, …) |
| `missing file: … (run from the checkout root)` | Run from the `agent_db` checkout root |
| `daemon NOT reachable` | Start it (`iex -S mix`), check `AGENT_DB_HTTP_PORT` matches `--port` |
| `mcp check inconclusive` | Expected with auth on (needs a token); otherwise check daemon logs |
| `doctor` reports DB unreachable | Check `data_dir` is writable; exits non-zero |
| Model load fails | Delete truncated cache file, re-run; check backend config |
| `/admin` 500 before routes | `SECRET_KEY_BASE` under 64 bytes — use a longer secret |
| `job_workers must be a positive integer` | Fix `AGENT_DB_JOB_WORKERS` to `1` or more |

`mix agent_db.doctor --json` prints the same report as JSON. `doctor` exits
non-zero only when the database itself is unreachable.
