#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.openchami-mcp.env"

MODE="${OPENCHAMI_MCP_MODE:-read-only}"
BASE_URL="${OPENCHAMI_BASE_URL:-}"
TIMEOUT="${OPENCHAMI_MCP_TIMEOUT:-10}"

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Start the OpenCHAMI MCP server (minikube-focused, local deployment).

Options:
  --mode MODE       MCP mode: read-only or read-write (default: read-only)
  --base-url URL    OpenCHAMI reverse-proxy base URL (default: auto-detect minikube ip -> :30080)
  --timeout N       HTTP request timeout in seconds (default: 10)
  --enable-writes   Export OPENCHAMI_MCP_ENABLE_WRITES=true for this process
  -h, --help        Show this help
EOF
}

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    MODE="${OPENCHAMI_MCP_MODE:-$MODE}"
    BASE_URL="${OPENCHAMI_BASE_URL:-$BASE_URL}"
    TIMEOUT="${OPENCHAMI_MCP_TIMEOUT:-$TIMEOUT}"
fi

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift
            ;;
        --base-url)
            BASE_URL="$2"
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift
            ;;
        --enable-writes)
            export OPENCHAMI_MCP_ENABLE_WRITES=true
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            show_help >&2
            exit 1
            ;;
    esac
    shift
done

if [[ "$MODE" != "read-only" && "$MODE" != "read-write" ]]; then
    echo "Error: --mode must be read-only or read-write." >&2
    exit 1
fi

if [ -z "$BASE_URL" ] && command -v minikube >/dev/null 2>&1; then
    MINIKUBE_IP="$(minikube ip 2>/dev/null || true)"
    if [ -n "$MINIKUBE_IP" ]; then
        BASE_URL="http://${MINIKUBE_IP}:30080"
    fi
fi

if [ -z "$BASE_URL" ]; then
    BASE_URL="http://192.168.100.2:30080"
fi

export OPENCHAMI_BASE_URL="$BASE_URL"
export OPENCHAMI_MCP_MODE="$MODE"
export OPENCHAMI_MCP_TIMEOUT="$TIMEOUT"

if [ "$MODE" = "read-write" ] && [[ "${OPENCHAMI_MCP_ENABLE_WRITES:-}" != "true" ]]; then
    echo "Warning: read-write mode selected but OPENCHAMI_MCP_ENABLE_WRITES=true is not set." >&2
    echo "         Write-capable tools will remain blocked until write ack is enabled." >&2
fi

exec python3 "$SCRIPT_DIR/openchami_mcp_server.py" \
    --base-url "$OPENCHAMI_BASE_URL" \
    --mode "$OPENCHAMI_MCP_MODE" \
    --timeout "$OPENCHAMI_MCP_TIMEOUT"
