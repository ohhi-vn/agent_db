#!/usr/bin/env bash
# AgentDb agent setup: checks prerequisites (via external package managers),
# prints ready-to-paste OpenCode and Zed snippets, and verifies the daemon.
#
# It never edits editor configs: paste the printed snippet yourself.
#
# Usage:
#   tools/install.sh [--check] [--port PORT]
#
#   --check  verify only (prerequisites, files, daemon reachability)
#   --port   daemon port (default: $AGENT_DB_HTTP_PORT or 6060)
set -u

PORT="${AGENT_DB_HTTP_PORT:-6060}"
MODE="install"
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --port=*) PORT="${arg#--port=}" ;;
    --port)
      echo "error: --port needs a value: --port=6060" >&2
      exit 2
      ;;
    -h|--help)
      echo "Usage: tools/install.sh [--check] [--port=PORT]"
      echo "  --check  verify only (prerequisites, files, daemon reachability)"
      echo "  --port   daemon port (default: \$AGENT_DB_HTTP_PORT or 6060)"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done
if [ "${1:-}" = "--port" ]; then
  PORT="${2:-}"
fi
case "$PORT" in
  ''|*[!0-9]*)
    echo "error: port must be numeric, got: $PORT" >&2
    exit 2
    ;;
esac

fail=0
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing: $1 -- $2" >&2
    fail=1
  fi
}

os_name="$(uname -s)"
case "$os_name" in
  Darwin) install_hint="brew install elixir" ;;
  Linux) install_hint="sudo apt install elixir (or use your distro's package)" ;;
  *) install_hint="install Elixir 1.20+ for your OS" ;;
esac

need elixir "install Elixir 1.20+: $install_hint"
need mix "ships with Elixir: $install_hint"
need curl "install curl to verify the daemon"

for f in mix.exs config/runtime.exs lib/agent_db_web/mcp.ex \
         lib/agent_db_web/controllers/mcp_controller.ex; do
  if [ ! -f "$f" ]; then
    echo "missing file: $f (run from the agent_db checkout root)" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "prerequisites incomplete; fix the lines above and re-run." >&2
  exit 1
fi

elixir_version="$(elixir --version 2>/dev/null | grep -o 'Elixir [0-9.]*' | awk '{print $2}')"
echo "prerequisites ok (elixir ${elixir_version:-unknown} on ${os_name})."

BASE_URL="http://127.0.0.1:${PORT}"
echo ""
echo "--- OpenCode snippet (paste into opencode.jsonc) ---"
cat <<EOF
{
  "mcp": {
    "servers": {
      "agent-db": {
        "type": "remote",
        "url": "${BASE_URL}/mcp"
      }
    }
  }
}
EOF
echo ""
echo "Bearer opt-in variant (when AGENT_DB_HTTP_AUTH=true):"
cat <<EOF
{
  "mcp": {
    "servers": {
      "agent-db": {
        "type": "remote",
        "url": "${BASE_URL}/mcp",
        "oauth": false,
        "headers": {
          "Authorization": "Bearer <token>"
        }
      }
    }
  }
}
EOF
echo ""
echo "--- Zed snippet (paste into settings.json under context_servers) ---"
cat <<EOF
{
  "context_servers": {
    "agent-db": {
      "url": "${BASE_URL}/mcp"
    }
  }
}
EOF
echo ""
echo "Bearer opt-in variant:"
cat <<EOF
{
  "context_servers": {
    "agent-db": {
      "url": "${BASE_URL}/mcp",
      "headers": {
        "Authorization": "Bearer <token>"
      }
    }
  }
}
EOF
echo ""
echo "Note: OpenCode uses \"command\": [...] (array) for local servers while"
echo "Zed uses \"command\": \"...\" plus separate \"args\": [...]; one snippet"
echo "cannot serve both editors verbatim. Remote URL shape is shared."

echo ""
echo "verifying daemon at ${BASE_URL} ..."
if curl -sf --max-time 5 "${BASE_URL}/api/v1/health" >/dev/null 2>&1; then
  echo "daemon reachable: ${BASE_URL}/api/v1/health answers."
else
  echo "daemon NOT reachable at ${BASE_URL}." >&2
  echo "start it first, e.g.: iex -S mix" >&2
  echo "or with auth: AGENT_DB_HTTP_AUTH=true AGENT_DB_HTTP_AUTH_TOKENS=<token> iex -S mix" >&2
  exit 1
fi

if curl -sf --max-time 10 -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    "${BASE_URL}/mcp" 2>/dev/null | grep -q 'context_read'; then
  echo "mcp verified: tools/list includes context_read."
else
  echo "mcp check inconclusive: tools/list did not answer as expected." >&2
  echo "(unauthenticated daemon should answer; with auth on, this check needs a token.)" >&2
  exit 1
fi

echo ""
echo "done. See docs/agents.md for the full setup guide."
