#!/bin/bash
set -e

# deploy.sh — Thin dispatcher for OpenCHAMI deployment
# Delegates to scripts/deploy/<method>.sh based on --method argument.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALID_METHODS="minikube, quadlets, docker-compose"
COMMON_SH="$SCRIPT_DIR/scripts/common.sh"

# shellcheck disable=SC1091
source "$COMMON_SH"

show_help() {
    echo "Usage: $0 --method <METHOD> [OPTIONS...]"
    echo ""
    echo "Deploy OpenCHAMI using the specified method."
    echo ""
    echo "Methods:"
    echo "  minikube         Deploy using Minikube (Linux: none driver, macOS: docker driver)"
    echo "  quadlets         Deploy using Podman Quadlet (systemd) [Linux only]"
    echo "  docker-compose   Deploy using Docker Compose"
    echo ""
    echo "Options:"
    echo "  --method METHOD        Deployment method ($VALID_METHODS)"
    echo "  --orchestrator METHOD  Backward-compatible alias for --method"
    echo "  -h, --help             Show this help (or method-specific help with --method)"
    echo ""
    add_common_deploy_args_help
    echo ""
    echo "Pass --help after --method for method-specific options:"
    echo "  $0 --method minikube --help"
}

METHOD=""
PASSTHROUGH_ARGS=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --method)
            METHOD="$2"
            shift 2
            ;;
        --orchestrator)
            echo "Warning: --orchestrator is deprecated, use --method instead." >&2
            # Map legacy values
            case "$2" in
                minikube) METHOD="$2" ;;
                podman) METHOD="quadlets" ;;
                *) METHOD="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            if [ -z "$METHOD" ]; then
                show_help
                exit 0
            fi
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ -z "$METHOD" ]; then
    echo "Error: --method is required." >&2
    echo "" >&2
    show_help >&2
    exit 1
fi

# Block quadlets on macOS (requires systemd)
if [[ "$(uname -s)" == "Darwin" && "$METHOD" == "quadlets" ]]; then
    echo "Error: 'quadlets' requires systemd and is not supported on macOS." >&2
    echo "Use --method docker-compose or --method minikube instead." >&2
    exit 1
fi

DEPLOY_SCRIPT="$SCRIPT_DIR/scripts/deploy/${METHOD}.sh"

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    echo "Error: Unknown method '$METHOD'. Valid methods: $VALID_METHODS" >&2
    exit 1
fi

exec bash "$DEPLOY_SCRIPT" "${PASSTHROUGH_ARGS[@]}"
